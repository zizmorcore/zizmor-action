#!/usr/bin/env bash

# checks.sh: publish zizmor JSON findings to a new GitHub check run.
# Called by action.sh with the results file and the scanner's exit status.
set -euo pipefail

results="${1}"
exitcode="${2}"
tempdir="$(mktemp -d "${RUNNER_TEMP}/zizmor-checks.XXXXXX")"
endpoint="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/check-runs"
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
check_id=""

api() {
    # Annotation updates append, so retrying an ambiguous failure can duplicate
    # findings. Leave retries to a new action invocation instead.
    if ! curl --silent --show-error --fail-with-body \
        --connect-timeout 10 --max-time 60 \
        --request "${1}" \
        --header "Authorization: Bearer ${GHA_ZIZMOR_TOKEN}" \
        --header 'Accept: application/vnd.github+json' \
        --header 'Content-Type: application/json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --data-binary @- --output "${tempdir}/response.json" "${2}"; then
        echo "::error::Checks reporting failed. Ensure the token has 'checks: write';" \
            "fork and Dependabot PR tokens are normally read-only."
        # Keep server messages on one prefixed line, without exposing the token.
        jq -r --arg token "${GHA_ZIZMOR_TOKEN}" '
            "GitHub response: " + (
                .message // "No API error message" |
                tostring | split($token) | join("***") | .[:1000] |
                @json | split("##[") | join("\\u0023#[")
            )
        ' "${tempdir}/response.json" 2>/dev/null || true
        return 1
    fi
}

cleanup() {
    local status=$?
    if [[ "${status}" -ne 0 && -n "${check_id}" ]]; then
        jq -n '{status: "completed", conclusion: "failure", output: {
            title: "zizmor reporting failed",
            summary: "Could not publish all results. See the workflow log for details."
        }}' | api PATCH "${endpoint}/${check_id}" || true
    fi
    rm -rf "${tempdir}"
}
trap cleanup EXIT

conclusion=failure
[[ "${exitcode}" -eq 0 ]] && conclusion=success

case "${exitcode}" in
    0|10|11|12|13|14)
        # JSON v1 uses zero-based rows. Like zizmor's workflow annotations, use
        # only the primary start line: multiline spans can extend past EOF.
        if ! jq -e --arg workspace "${GITHUB_WORKSPACE}" '
            def normalize:
                split("/") | reduce .[] as $part ([];
                    if $part == "" or $part == "." then .
                    elif $part == ".." then .[:-1]
                    else . + [$part] end) | "/" + join("/");
            (($workspace | normalize) + "/") as $root |
            if type != "array" then error("expected findings array") else . end |
            map(select(.ignored != true) |
                . as $finding |
                ([.locations[] | select(.symbolic.kind == "Primary")][0]
                    // error("finding has no primary location")) as $primary |
                $primary.symbolic.key as $key |
                ($key.Local.verbatim_path // $key.Local.given_path) as $local |
                (if $local == null then null else
                    ($local | if startswith("/") then . else $root + . end | normalize) |
                    if startswith($root) then ltrimstr($root) else null end
                end) as $path |
                {
                    path: $path,
                    display_path: ($local // $key.Remote.path // "stdin"),
                    severity: $finding.determinations.severity,
                    description: $finding.desc,
                    url: $finding.url,
                    start_line: ($primary.concrete.location.start_point.row + 1),
                    end_line: ($primary.concrete.location.start_point.row + 1),
                    annotation_level: ({
                        Unknown: "notice",
                        Informational: "notice",
                        Low: "warning",
                        Medium: "warning",
                        High: "failure"
                    }[$finding.determinations.severity] // error("unknown severity")),
                    title: $finding.ident[:255],
                    message: "\($finding.desc): \($primary.symbolic.annotation)\n\($finding.url)"
                })
        ' "${results}" > "${tempdir}/findings.json"; then
            echo "::error::Could not read zizmor JSON results for Checks reporting"
            exit 1
        fi

        # JSON quoting keeps each finding on one prefixed line. Also escape the
        # legacy command prefix, which the runner recognizes anywhere in a line.
        jq -r '
            .[] | "Finding: " + (
                "\(.display_path):\(.start_line): \(.title): \(.message)" |
                @json | split("##[") | join("\\u0023#[")
            )
        ' "${tempdir}/findings.json"
        # 16,000 Unicode code points fit within the API limit of 64 KB.
        jq 'map(select(.path != null) |
            del(.display_path, .severity, .description, .url) | .message |= .[:16000])' \
            "${tempdir}/findings.json" > "${tempdir}/annotations.json"
        count="$(jq length "${tempdir}/annotations.json")"

        jq --arg run_url "${run_url}" \
            --arg source_url "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/blob/${GITHUB_SHA}/" '
            def cell:
                @html | gsub("\\|"; "&#124;") |
                gsub("\\["; "&#91;") | gsub("\\]"; "&#93;") |
                gsub("`"; "&#96;") | gsub("\\\\"; "&#92;") |
                gsub("\\*"; "&#42;") | gsub("_"; "&#95;") |
                gsub("~"; "&#126;") | gsub("[\r\n]"; " ");
            def row:
                ("<code>\((.path // .display_path) | cell):\(.start_line)</code>") as $label |
                (if .path == null then $label else
                    (.path | split("/") | map(@uri) | join("/")) as $path |
                    "[\($label)](\($source_url)\($path)#L\(.start_line))"
                end) as $location |
                "| \(.severity) | [\(.title | cell)](\(.url)) | " +
                "\($location) | \(.description | cell) |\n";
            . as $findings |
            length as $total |
            (map(select(.path == null)) | length) as $unattached |
            (reduce .[:50][] as $finding ({
                text: ("| Severity | Rule | Location | Finding |\n" +
                    "| --- | --- | --- | --- |\n"),
                shown: 0
            };
                ($finding | row) as $row |
                # Leave room beneath the API text limit for the truncation notice.
                if ((.text + $row) | utf8bytelength) <= 60000 then
                    .text += $row | .shown += 1
                else . end
            )) as $report |
            {
                title: (if $total == 0 then "No findings" else
                    "\($total) finding\(if $total == 1 then "" else "s" end)"
                end),
                summary: (
                    if $total == 0 then "🌈 No findings to report."
                    else
                        "**\($total) findings**\n\n| Severity | Count |\n| --- | ---: |\n" +
                        (["High", "Medium", "Low", "Informational", "Unknown"] |
                            map(. as $severity |
                                ($findings | map(select(.severity == $severity)) | length)
                                as $count |
                                select($count > 0) | "| \($severity) | \($count) |"
                            ) | join("\n"))
                    end +
                    (if $unattached > 0 then
                        "\n\n\($unattached) findings have no local file annotation; " +
                        "see the report below and the workflow log."
                    else "" end) +
                    "\n\n[View workflow run and logs](\($run_url))"
                ),
                text: (if $total == 0 then "" else
                    $report.text + (if $report.shown < $total then
                        "\nShowing \($report.shown) of \($total) findings. " +
                        "See the annotations and workflow log for the remaining findings."
                    else "" end)
                end)
            }
        ' "${tempdir}/findings.json" > "${tempdir}/report.json"
        ;;
    *)
        echo '[]' > "${tempdir}/annotations.json"
        count=0
        if [[ "${exitcode}" -eq 3 ]]; then
            title="No inputs collected"
            summary="No inputs were collected by zizmor."
            [[ "${GHA_ZIZMOR_FAIL_ON_NO_INPUTS}" == "false" ]] && conclusion=success
        else
            title="Analysis failed"
            summary="zizmor failed with exit code ${exitcode}. See the workflow log for details."
        fi
        jq -n --arg title "${title}" --arg summary "${summary}" --arg run_url "${run_url}" \
            '{title: $title, text: "",
                summary: ($summary + "\n\n[View workflow run and logs](" + $run_url + ")")}' \
            > "${tempdir}/report.json"
        ;;
esac

jq -n --arg name "${GHA_ZIZMOR_INTERNAL_CHECKS_NAME}" --arg sha "${GITHUB_SHA}" \
    --arg url "${run_url}" \
    '{name: $name, head_sha: $sha, details_url: $url, status: "in_progress"}' \
    | api POST "${endpoint}"
check_id="$(jq -er '.id | select(type == "number")' "${tempdir}/response.json")"

for ((offset = 0; offset < count; offset += 50)); do
    jq --argjson offset "${offset}" --slurpfile report "${tempdir}/report.json" \
        '{output: (($report[0] | del(.text)) + {annotations: .[$offset:$offset + 50]})}' \
        "${tempdir}/annotations.json" \
        | api PATCH "${endpoint}/${check_id}"
done

jq --arg conclusion "${conclusion}" \
    '{status: "completed", conclusion: $conclusion, output: .}' "${tempdir}/report.json" \
    | api PATCH "${endpoint}/${check_id}"

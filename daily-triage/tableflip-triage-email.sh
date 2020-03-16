#!/bin/bash
#
# Note: this job relies on the system's ability to send mail via /usr/sbin/sendmail.
#
# To run this script without sending mail, set TRIAGE_NO_SENDMAIL non-empty in
# the environment.

set -eufx -o pipefail

export LC_ALL=C.UTF-8

TRIAGE_NO_SENDMAIL="${TRIAGE_NO_SENDMAIL-""}"


# Do we have the required tools?
command -v ubuntu-bug-triage
[ -z "$TRIAGE_NO_SENDMAIL" ] && command -v /usr/sbin/sendmail


# Projects to triage
projects="cloud-init curtin simplestreams"
github_projects="cloud-init"
ndays_new_bugs=90

# GitHub usernames of core committers, comma-separated for use in jq filters
core_committers="blackboxsw,OddBloke,raharper"


# Find today's triager. On Mondays triage the weekend's bugs.
ndays=1
triagers=(Dan Ryan Chad Paride)
week=$(date --utc '+%-V')
dow=$(date --utc '+%u')
if [[ "$dow" -ge 2 && "$dow" -le 5 ]]; then
    ndays=1
    triager=${triagers[$((dow-2))]}
elif [[ "$dow" -eq 1 ]]; then
    # Mondays!
    ndays=3
    triager=${triagers[$((week%4 - 1))]}
else
    ndays=1
    triager="nobody"
fi


# Retrieve the bugs
for project in $projects; do
    : > "$project-bugs.text"
    echo "[Incomplete, Confirmed, Triaged and In Progress bugs]" > "$project-bugs.text.tmp"
    ubuntu-bug-triage --anon -s Incomplete -s Confirmed -s Triaged -s "In Progress" --include-project "$project" "$ndays" >> "$project-bugs.text.tmp"
    grep -q LP "$project-bugs.text.tmp" && cat "$project-bugs.text.tmp" > "$project-bugs.text"
    echo "[New bugs]" > "$project-bugs.text.tmp"
    ubuntu-bug-triage --anon -s New --include-project "$project" "$ndays_new_bugs" >> "$project-bugs.text.tmp"
    if grep -q LP "$project-bugs.text.tmp"; then
        [[ -s $project-bugs.text ]] && echo >> "$project-bugs.text"
        cat "$project-bugs.text.tmp" >> "$project-bugs.text"
    fi
    rm -f "$project-bugs.text.tmp"
done


for project in $github_projects; do
    : > "$project-reviews.text"

    # Fetch all pull requests
    curl "https://api.github.com/repos/canonical/$project/pulls" > pulls.json

    # Reverse order so oldest are displayed first, convert to JSON Lines to
    # reduce repeated work in next step, filter out assigned PRs, filter out
    # PRs submitted by core committers
    jq -r "reverse | .[] | select(.assignee == null) | select(.user.login | inside(\"$core_committers\") | not)" pulls.json > relevant_pulls.jsonl

    # Use jq's string interpolation to generate the text and HTML output
    jq -r '"* PR #\(.number): \"\(.title)\" by @\(.user.login)\n  \(.html_url)"' relevant_pulls.jsonl \
        > "$project-reviews.text"
    jq -r '"<li><a href=\"\(.html_url)\">PR #\(.number)</a>: \"\(.title)\" by @\(.user.login)"' relevant_pulls.jsonl \
        > "$project-reviews.html"
    rm -f pulls.json relevant_pulls.jsonl
done


# Generate the email subject and <title> for the text/html email
subject="Daily triage for: $projects [$triager]"


# Generate the text/plain mail body
{
    printf '# Daily bug triage for: %s\n\n' "$projects"
    echo "Today's triager: $triager"

    for project in $projects; do
        printf '\n## %s active bugs (%s days) and New bugs (%s days)\n\n' "$project" $ndays $ndays_new_bugs
        cat "$project-bugs.text"

        if [ -e "$project-reviews.text" ]; then
            printf '\n## %s reviews without an assignee\n\n' "$project"
            cat "$project-reviews.text"
        fi
    done

    printf '\n## Schedule\n\n'
    echo "Mon: <varies>"
    i=0
    for d in Tue Wed Thu Fri; do
        echo "$d: ${triagers[$i]}"
        i=$((i+1))
    done
    printf '\nMondays follow the same schedule, starting from\nthe first Monday of the year. Next Mondays:\n\n'
    for i in {1..5}; do
        future_date=$(date --utc --date="$i Monday" '+%b %_d')
        future_week=$(date --utc --date="$i Monday" '+%-V')
        future_triager=${triagers[$((future_week%4 - 1))]}
        echo "$future_date: $future_triager"
    done
} > mail-body.text


# Generate the text/html mail body (a valid HTML5 document)
{
    printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n'
    echo "<title>$subject</title>"
    printf '</head>\n<body>\n'
    echo "<h4>Daily bug triage for: $projects</h4>"
    echo "Today's triager: $triager"

    for project in $projects; do
        sed 's|\(LP: #\)\([0-9][0-9]*\)|LP: <a href="https://pad.lv/\2">#\2</a>|' "$project-bugs.text" > "$project-bugs.html"
        echo "<h5>$project active bugs ($ndays days) and New bugs ($ndays_new_bugs days)</h5>"
        echo "<pre>"
        cat "$project-bugs.html"
        echo "</pre>"

        if [ -e "$project-reviews.html" ]; then
            echo "<h5>$project reviews without an assignee</h5>"
            echo "<ul>"
            cat "$project-reviews.html"
            echo "</ul>"
        fi
    done

    echo "<h5>Schedule</h5>"
    echo "<ul>"
    echo "<li>Mon: &lt;varies&gt;</li>"
    i=0
    for d in Tue Wed Thu Fri; do
        echo "<li>$d: ${triagers[$i]}</li>"
        i=$((i+1))
    done
    echo "</ul>"
    echo "Mondays follow the same schedule, starting from the first Monday of the year. Next Mondays:"
    echo "<ul>"
    for i in {1..5}; do
        future_date=$(date --utc --date="$i Monday" '+%b %_d')
        future_week=$(date --utc --date="$i Monday" '+%-V')
        future_triager=${triagers[$((future_week%4 - 1))]}
        echo "<li>$future_date: $future_triager</li>"
    done
    echo "</ul>"
    printf '</body>\n</html>\n'
} > mail-body.html


# Generate the full multipart/alternative email message
{
    recipients="server-table-flip@lists.canonical.com"
    mpboundary="multipart-boundary-$(date --utc '+%s%N')"
    cat <<-EOF
	From: server@jenkins.canonical.com
	To: $recipients
	Subject: $subject
	MIME-Version: 1.0
	Content-Type: multipart/alternative; boundary="$mpboundary"

	--$mpboundary
	Content-type: text/plain; charset="UTF-8"

	EOF
    cat mail-body.text
    cat <<-EOF
	--$mpboundary
	Content-type: text/html; charset="UTF-8"

	EOF
    cat mail-body.html
    echo "--$mpboundary--"
} > mail-smtp


# Send the email.
if [ -z "$TRIAGE_NO_SENDMAIL" ]; then
    /usr/sbin/sendmail -t < mail-smtp
else
    echo "Mail output in mail-smtp"
fi

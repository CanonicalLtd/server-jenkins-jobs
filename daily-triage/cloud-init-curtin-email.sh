#!/bin/bash -ex
#
# Note: this job relies on the system's ability to send mail using msmtp(1).

export LC_ALL=C.UTF-8


# Do we have the required tools?
command -v ubuntu-bug-triage
command -v msmtp


# Find today's triager. On Mondays triage the weekend's bugs.
ndays=1
triagers=(Dan Ryan Chad Paride)
week=$(date --utc '+%-V')
dow=$(date --utc '+%u')
if [ $dow -ge 2 -a $dow -le 5 ]; then
    ndays=1
    triager=${triagers[$(($dow-2))]}
elif [ $dow -eq 1 ]; then
    # Mondays!
    ndays=3
    triager=${triagers[$(($week%4 - 1))]}
else
    ndays=1
    triager="nobody"
fi


# Retrieve the bugs
ubuntu-bug-triage --anon --include-project cloud-init $ndays > cloud-init-bugs.text
ubuntu-bug-triage --anon --include-project curtin $ndays > curtin-bugs.text


# Generate the email subject and <title> for the text/html email
today=$(date --utc '+%b %-d')
subject="Daily cloud-init/curtin bug triage: $today [$triager]"


# Generate the text/plain mail body
echo -e "# Daily bug triage for cloud-init and curtin\n" > mail-body.text
echo "Today's triager: $triager" >> mail-body.text
echo -e "\n## cloud-init bugs for the last $ndays day(s)\n" >> mail-body.text
cat cloud-init-bugs.text >> mail-body.text
echo -e "\n## curtin bugs for the last $ndays day(s)\n" >> mail-body.text
cat curtin-bugs.text >> mail-body.text
echo -e "\n## Schedule\n" >> mail-body.text
echo "Mon: <varies>" >> mail-body.text
i=0
for d in Tue Wed Thu Fri; do
    echo "$d: ${triagers[$i]}" >> mail-body.text
    i=$(($i+1))
done
echo -e "\nMondays follow the same schedule, starting from" >> mail-body.text
echo -e "the first Monday of the year. Next Mondays:\n" >> mail-body.text
for i in {1..5}; do
    future_date=$(date --utc --date="$i Monday" '+%b %_d')
    future_week=$(date --utc --date="$i Monday" '+%-V')
    future_triager=${triagers[$(($future_week%4 - 1))]}
    echo "$future_date: $future_triager" >> mail-body.text
done


# Generate the text/html mail body (a valid HTML5 document)
sed 's|\(LP: #\)\([0-9][0-9]*\)|LP: <a href="https://pad.lv/\2">#\2</a>|' cloud-init-bugs.text > cloud-init-bugs.html
sed 's|\(LP: #\)\([0-9][0-9]*\)|LP: <a href="https://pad.lv/\2">#\2</a>|' curtin-bugs.text > curtin-bugs.html
echo -e '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">' > mail-body.html
echo "<title>$subject</title>" >> mail-body.html
echo -e "</head>\n<body>" >> mail-body.html
echo "<h4>Daily bug triage for cloud-init and curtin</h4>" >> mail-body.html
echo "Today's triager: $triager" >> mail-body.html
echo "<h5>cloud-init bugs for the last $ndays day(s)</h5>" >> mail-body.html
echo "<pre>" >> mail-body.html
cat cloud-init-bugs.html >> mail-body.html
echo "</pre>" >> mail-body.html
echo "<h5>curtin bugs for the last $ndays day(s)</h5>" >> mail-body.html
echo "<pre>" >> mail-body.html
cat curtin-bugs.html >> mail-body.html
echo -e "</pre>" >> mail-body.html
echo -e "<h5>Schedule</h5>" >> mail-body.html
echo -e "<ul>" >> mail-body.html
echo "<li>Mon: &lt;varies&gt;</li>" >> mail-body.html
i=0
for d in Tue Wed Thu Fri; do
    echo "<li>$d: ${triagers[$i]}</li>" >> mail-body.html
    i=$(($i+1))
done
echo "</ul>" >> mail-body.html
echo "Mondays follow the same schedule, starting from the first Monday of the year. Next Mondays:" >> mail-body.html
echo "<ul>" >> mail-body.html
for i in {1..5}; do
    future_date=$(date --utc --date="$i Monday" '+%b %_d')
    future_week=$(date --utc --date="$i Monday" '+%-V')
    future_triager=${triagers[$(($future_week%4 - 1))]}
    echo "<li>$future_date: $future_triager</li>" >> mail-body.html
done
echo "</ul>" >> mail-body.html
echo -e "</body>\n</html>" >> mail-body.html


# Generate the full multipart/alternative email message
mpboundary="multipart-boundary-$(date --utc '+%s%N')"
cat > mail-smtp <<EOF
From: server@jenkins.canonical.com
To: josh.powers@canonical.com
To: paride.legovini@canonical.com
To: daniel.watkins@canonical.com
To: chad.smith@canonical.com
To: ryan.harper@canonical.com
Subject: $subject
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="$mpboundary"

--$mpboundary
Content-type: text/plain; charset="UTF-8"

EOF
cat mail-body.text >> mail-smtp

cat >> mail-smtp <<EOF
--$mpboundary
Content-type: text/html; charset="UTF-8"

EOF
cat mail-body.html >> mail-smtp
echo "--$mpboundary--" >> mail-smtp


# Send the email. This will work only for @canonical.com addresses.
msmtp --host=mx.canonical.com --read-envelope-from -t < mail-smtp

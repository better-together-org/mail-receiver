#!/bin/bash

set -e

# Send syslog messages to stderr, optionally relaying them to another socket
# for postfix-exporter to take a look at
if [ -z "$SOCKETEE_RELAY_SOCKET" ]; then
	/usr/bin/socat UNIX-RECV:/dev/log,mode=0666 stderr &
else
	/usr/local/bin/socketee /dev/log "$SOCKETEE_RELAY_SOCKET" &
fi

echo "Operating environment:" >&2
env >&2

ruby -rjson -e "File.write('/etc/postfix/mail-receiver-environment.json', ENV.to_hash.to_json)"

if [ -z "$MAIL_DOMAIN" ]; then
	echo "FATAL ERROR: MAIL_DOMAIN env var is not set." >&2
	exit 1
fi

# CE_MAIL_DOMAINS is a space-separated subset of MAIL_DOMAIN that should
# route to the Community Engine target instead of Discourse. A single
# container can serve both kinds of domain at once, each with its own
# distinct credentials (DISCOURSE_* vs CE_*).
/usr/sbin/postconf -e relay_domains="$MAIL_DOMAIN"
rm -f /etc/postfix/transport
ce_domain_count=0
discourse_domain_count=0
for d in $MAIL_DOMAIN; do
	is_ce=0
	for ced in $CE_MAIL_DOMAINS; do
		if [ "$d" = "$ced" ]; then is_ce=1; fi
	done
	if [ "$is_ce" = "1" ]; then
		echo "Delivering mail sent to $d to Community Engine" >&2
		/bin/echo "$d ce:" >>/etc/postfix/transport
		ce_domain_count=$((ce_domain_count + 1))
	else
		echo "Delivering mail sent to $d to Discourse" >&2
		/bin/echo "$d discourse:" >>/etc/postfix/transport
		discourse_domain_count=$((discourse_domain_count + 1))
	fi
done
/usr/sbin/postmap /etc/postfix/transport

# Make sure the necessary Discourse connection details are in place, but
# only if at least one MAIL_DOMAIN actually routes there.
if [ "$discourse_domain_count" -gt 0 ]; then
	for v in DISCOURSE_API_KEY DISCOURSE_API_USERNAME; do
		if [ -z "${!v}" ]; then
			echo "FATAL ERROR: $v env var is not set (required: at least one MAIL_DOMAIN routes to Discourse)." >&2
			exit 1
		fi
	done

	if [ -z "$DISCOURSE_BASE_URL" ] && [ -z "$DISCOURSE_MAIL_ENDPOINT" ] ; then
		echo "FATAL ERROR: You need to define DISCOURSE_BASE_URL or DISCOURSE_MAIL_ENDPOINT" >&2
		exit 1
	fi
fi

# Make sure the necessary CE connection details are in place, but only if
# at least one MAIL_DOMAIN actually routes there.
if [ "$ce_domain_count" -gt 0 ]; then
	for v in CE_API_KEY CE_API_USERNAME CE_MAIL_ENDPOINT; do
		if [ -z "${!v}" ]; then
			echo "FATAL ERROR: $v env var is not set (required: at least one MAIL_DOMAIN routes to Community Engine)." >&2
			exit 1
		fi
	done
fi

# Generic postfix config setting code... bashers gonna bash.
for envvar in $(compgen -v); do
	if [[ "$envvar" =~ ^POSTCONF_ ]]; then
		varname="${envvar/POSTCONF_/}"
		echo "Setting $varname to '${!envvar}'" >&2
		/usr/sbin/postconf -e $varname="${!envvar}"
	fi
done

if [ "$INCLUDE_DMARC" = "true" ]; then
  echo "Starting OpenDKIM..." >&2
  adduser postfix opendkim #ensure postfix is part of opendkim group so it can access the socket
  /usr/sbin/opendkim -x /etc/opendkim.conf

  echo "Starting OpenDMARC..." >&2
  adduser postfix opendmarc #ensure postfix is part of opendmarc group so it can access the socket
  /usr/sbin/opendmarc -c /etc/opendmarc.conf
fi

# Now, make sure that the Postfix filesystem environment is sane
mkdir -p -m 0755 /var/spool/postfix/pid
chown root:root /var/spool/postfix

# Permissions are sensitive for postfix to work correctly; ensure the directory
# permissions are set as expected.
chown --recursive postfix:root /var/spool/postfix/*
[[ -d /var/spool/postfix/maildrop ]] && chown --recursive postfix:postdrop /var/spool/postfix/maildrop
[[ -d /var/spool/postfix/public ]] && chown --recursive postfix:postdrop /var/spool/postfix/public
chown --recursive root:root /var/spool/postfix/pid

/usr/sbin/postfix check >&2

echo "Starting Postfix" >&2

# Finally, let postfix-master do its thing
exec /usr/lib/postfix/sbin/master -c /etc/postfix -d

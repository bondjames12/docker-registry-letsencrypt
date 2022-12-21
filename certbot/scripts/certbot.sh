#!/bin/sh

# script bases on https://github.com/janeczku/haproxy-acme-validation-plugin/blob/master/cert-renewal-haproxy.sh

log_lvl_error() {
  NOW=$(date +"%Y/%m/%d %H:%M:%S")
  if [ -n "${LOGFILE}" ]
  then
    echo "${NOW} [error] ${1}" >> ${LOGFILE}
  fi
  >&2 echo "${NOW} [error] ${1}" > /proc/1/fd/1 2>/proc/1/fd/2
}

log_lvl_info() {
  NOW=$(date +"%Y/%m/%d %H:%M:%S")
  if [ -n "${LOGFILE}" ]
  then
    echo "${NOW} [info] ${1}" >> ${LOGFILE}
  else
    echo "${NOW} [info] ${1}" > /proc/1/fd/1 2>/proc/1/fd/2
  fi
}

issueCertificate() {
  log_lvl_info "issueCertificate Running Email:$EMAIL Certbot Args:$CERTBOT_ARGS Arg1:$1"
  log_lvl_info "certbot certonly -vvv --agree-tos --renew-by-default --non-interactive --max-log-backups 100 --email $EMAIL $CERTBOT_ARGS -d $1"
  certbot certonly -vvv --agree-tos --renew-by-default --non-interactive --max-log-backups 100 --email $EMAIL $CERTBOT_ARGS -d $1 >> ${LOGFILE}
  return $?
}

renewedCertsHook() {
    #hook to end of process of renewing certificates
    if [ ! -z "${RENEWED_CERTS_HOOK}" ]; then
        sh -c "${RENEWED_CERTS_HOOK}"
        log_lvl_info "Renewed Certs Hook executed"
    fi
}

copyCertificate() {
  local d=${CERT_DOMAIN} # shorthand

  #rename certificates and copy them into a flat hierarchy
  cp /etc/letsencrypt/live/$d/cert.pem /certs/$d.pem
  cp /etc/letsencrypt/live/$d/privkey.pem /certs/$d.key.pem
  cp /etc/letsencrypt/live/$d/chain.pem /certs/$d.chain.pem
  cp /etc/letsencrypt/live/$d/fullchain.pem /certs/$d.fullchain.pem
  log_lvl_info "Certificates for $d and copied to /certs dir"
  renewedCertsHook
}


# Get the certificate for the domain(s) CERT_DOMAIN (a comma separated list)
# The certificate will be named after the first domain in the list
# To work, the following variables must be set:
# - CERT_DOMAIN : comma separated list of domains
# - EMAIL
# - CONCAT
# - CERTBOT_ARGS
processCertificates() {
  local d=${CERT_DOMAIN} # shorthand

  if [ -d /etc/letsencrypt/live/$d ]; then
    cert_path=$(find /etc/letsencrypt/live/$d -name cert.pem -print0)
    if [ $cert_path ]; then
      # check for certificates expiring in less that 28 days
      if ! openssl x509 -noout -checkend $((4*7*86400)) -in "${cert_path}"; then
        subject="$(openssl x509 -noout -subject -in "${cert_path}" | grep -o -E 'CN=[^ ,]+' | tr -d 'CN=')"
        subjectaltnames="$(openssl x509 -noout -text -in "${cert_path}" | sed -n '/X509v3 Subject Alternative Name/{n;p}' | sed 's/\s//g' | tr -d 'DNS:' | sed 's/,/ /g')"
        domains="${subject}"

        # look for certificate additional domain names and append them as '-d <name>' (-d for certbot's --domains option)
        for altname in ${subjectaltnames}; do
          if [ "${altname}" != "${subject}" ] && ["${altname}" != ""]; then
            domains="${domains} -d ${altname}"
          fi
          if ["${subject}" == ""] && ["${altname}" != ""; then
            domains="${altname}"
          fi
        done

        # renewing certificate
        log_lvl_info "Renewing certificate for $domains"
        issueCertificate "${CERT_DOMAIN}"
        if [ $? -ne 0 ]; then
          log_lvl_error "Failed to renew certificate! check /var/log/letsencrypt/letsencrypt.log!"
          exitcode=1
        else
          log_lvl_info "Renewed certificate for ${subject}"
          copyCertificate
        fi

      else
        log_lvl_info "Certificate for $d does not require renewal"
        copyCertificate
      fi
    fi
  else
    # initial certificate request
    log_lvl_info "Getting certificate for $CERT_DOMAIN"
    issueCertificate "${CERT_DOMAIN}"

    if [ $? -ne 0 ]; then
      log_lvl_error "Failed to request certificate! check /var/log/letsencrypt/letsencrypt.log!"
      exitcode=1
    else
      log_lvl_info "Certificate delivered for $CERT_DOMAIN"
      copyCertificate
    fi
  fi
}

# create dummy certificates to enable nginx etc. to start
createDummyCertificates() {
    local d=${CERT_DOMAIN} # shorthand

    openssl req -x509 -nodes -newkey rsa:1024 -days 1 -keyout "/certs/${d}.key.pem" \
    -out "/certs/${d}.fullchain.pem" \
    -subj '/CN=localhost'
}

# perform healthcheck - is $HEALTH_CHECK_URL online?
waitUntilHealthCheckUrlIsOnline() {
    if [ -z $HEALTH_CHECK_URL ]; then
        log_lvl_info "No HEALTH_CHECK_URL configured. Starting certbot without healthcheck"
    else
        # Wait for provided $HEALTH_CHECK_URL to become online
        until [ $(curl -s -k -L --head --fail -o /dev/null -w '%{http_code}\n' --connect-timeout 3 --max-time 5 $HEALTH_CHECK_URL) -eq 200 ]; do
          printf '.'
          sleep 5
        done
    log_lvl_info "$HEALTH_CHECK_URL is online."
    fi
}

################################
# CERTBOT MAIN ROUTINE
################################

# certbot arguments
# default to standalone mode with http challenge
CERTBOT_ARGS="--standalone --preferred-challenges http"

# activate debug mode
if [ "$DEBUG" = true ]; then
  CERTBOT_ARGS=$CERTBOT_ARGS" --debug"
fi

# activate staging mode where test certificates (invalid) are requested against
# letsencrypt's staging server https://acme-staging.api.letsencrypt.org/directory.
# This is useful for testing purposes without being rate limited by letsencrypt
if [ "$STAGING" = true ]; then
  CERTBOT_ARGS=$CERTBOT_ARGS" --staging"
fi

log_lvl_info "Checking certificates for domains $DOMAINS"

##
# extract certificate domains and run main routine on each
# $DOMAINS is expected to be space separated list of domains such as in "domain1.tld domain2.tld domain3.tld"
# each domains subset can be composed of several domains in case of multi-host domains,
# they are expected to be comma separated, such as in "domain1.tld sub.domain.tld,sub1.domain.tld domain3.tld"
#
for d in $DOMAINS; do
  CERT_DOMAIN=$d
  createDummyCertificates
  waitUntilHealthCheckUrlIsOnline
  processCertificates
done

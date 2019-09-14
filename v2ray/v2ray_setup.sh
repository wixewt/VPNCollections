#!/bin/bash

ORI_USER="$(who am i | awk '{print $1}')"
ORI_USER_HOME="$( getent passwd $ORI_USER | cut -d: -f6)"

#update/create dns record
update_dns_record(){

  PUB_IPv4="$(curl -s -4 ifconfig.co)"
  PRI_IPv4="$(ip route get 8.8.8.8| awk '{print $7}')"

  PUB_IPv6="$(curl -s -6 ifconfig.co)"
  PRI_IPv6="$(ip route get 2001:4860:4860::8844| awk '{print $9}')"

  local JSON="$(curl -sS "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")"
  local ZONE_ID="$(sed -ne 's/.*"id":"\(.*\)","name":"'"$DOMAIN"'".*/\1/p' <<< $JSON)"

  if [[ -z "$ZONE_ID" ]]
  then
    echo "Cannot get Zone ID. Will not update DNS record"
  else
    echo "Will try update DNS record by hostname";
    local JSON="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=$SITE" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")"
    local IPv4_ID="$(sed -ne 's/.*"id":"\(.*\)","type":"A","name":".*'"$DOMAIN"'",.*/\1/p' <<< $JSON)"

    if [[ -z "$IPv4_ID" ]]
    then
      curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"$SITE\",\"content\":\"${PUB_IPv4}\",\"ttl\":1}"
    else
      curl -sS -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${IPv4_ID}" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"$SITE\",\"content\":\"${PUB_IPv4}\",\"ttl\":1}"
    fi

    local JSON="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=AAAA&name=$SITE" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")"
    local IPv6_ID="$(sed -ne 's/.*"id":"\(.*\)","type":"AAAA","name":".*'"$DOMAIN"'",.*/\1/p' <<< $JSON)"

    if [[ -z "$IPv6_ID" ]]
    then
      curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" --data "{\"type\":\"AAAA\",\"name\":\"$SITE\",\"content\":\"${PUB_IPv6}\",\"ttl\":1}"
    else
      curl -sS -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${IPv6_ID}" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" --data "{\"type\":\"AAAA\",\"name\":\"$SITE\",\"content\":\"${PUB_IPv6}\",\"ttl\":1}"
    fi
  fi
}

# setup caddy
setup_caddy(){
  # caddy install script
  curl -s https://getcaddy.com | bash -s personal tls.dns.cloudflare

  # some trivial config
  ulimit -n 16384
  echo '* soft nofile 16384' >> /etc/security/limits.conf
  echo '* hard nofile 16384' >> /etc/security/limits.conf

  # caddy permissions
  chown root:root /usr/local/bin/caddy
  chmod 755 /usr/local/bin/caddy

  # create user and group for caddy
  groupadd -g 9999 www-data
  useradd \
    -g www-data --no-user-group \
    --home-dir /var/www --no-create-home \
    --shell /usr/sbin/nologin \
    --system --uid 9999 www-data

  # caddy folder and its permissions
  mkdir /etc/caddy
  chown -R root:root /etc/caddy
  mkdir /etc/ssl/caddy
  chown -R root:www-data /etc/ssl/caddy
  chmod 0770 /etc/ssl/caddy

  # create Caddyfile
  # error log?
  cat >/etc/caddy/Caddyfile <<_EOF_
$SITE {
  root /var/www
  gzip {
      ext .html .htm
      level 6
  }
  proxy /w localhost:10000 {
    websocket
    header_upstream -Origin
  }
  proxy /h https://localhost:11000 {
    insecure_skip_verify
    header_upstream X-Forwarded-Proto "https"
    header_upstream Host "$SITE"
  }
  header / {
      Strict-Transport-Security "max-age=31536000;"
      X-XSS-Protection "1; mode=block"
      X-Content-Type-Options "nosniff"
      X-Frame-Options "DENY"
  }
  tls {
    dns cloudflare
  }
}
_EOF_

  chown root:root /etc/caddy/Caddyfile
  chmod 644 /etc/caddy/Caddyfile

  mkdir /var/www
  cat >/var/www/index.html <<_EOF_
<!DOCTYPE html>
<html>
  <head>
    <title>Hello from Caddy!</title>
  </head>
  <body>
    <h1 style="font-family: sans-serif">This page is being served via Caddy</h1>
  </body>
</html>
_EOF_

  chown -R www-data:www-data /var/www
  chmod 555 /var/www

  # get service file and make the configuration 
  curl -L -s https://raw.githubusercontent.com/caddyserver/caddy/master/dist/init/linux-systemd/caddy.service | \
    sed -e '/Environment=.*/a Environment=CLOUDFLARE_EMAIL='"$CF_EMAIL"'\nEnvironment=CLOUDFLARE_API_KEY='"$CF_KEY" \
    -e 's_ReadWritePaths=_ReadWriteDirectories=_g' \
    -e 's|-agree=true|-agree=true -email='"$CERT_EMAIL"'|g' \
    -e 's|;CapabilityBoundingSet=|CapabilityBoundingSet=|g' \
    -e 's|;AmbientCapabilities=|AmbientCapabilities=|g' \
    -e 's|;NoNewPrivileges=|NoNewPrivileges=|g' \
    >/etc/systemd/system/caddy.service
  
  # enabling service
  chown root:root /etc/systemd/system/caddy.service
  chmod 644 /etc/systemd/system/caddy.service
  systemctl daemon-reload
  systemctl start caddy.service
  systemctl enable caddy.service

  #firewall rules for caddy
  firewall-cmd --permanent --zone=public --add-service=http
  firewall-cmd --permanent --zone=public --add-service=https
  firewall-cmd --reload
}

# setup v2ray
setup_v2ray(){
  # v2ray install script
  curl -L -s https://install.direct/go.sh | bash -s

  # backup the config file just for fallback and testing if needed
  \cp /etc/v2ray/config.json /etc/v2ray/config.json.bak

  # get the UUID
  # the following should work too
  # cat /proc/sys/kernel/random/uuid
  # python -c "import uuid; print(uuid.uuid4());"
  # curl https://www.uuidgenerator.net/api/version4
  UUID="$(uuidgen -r)"

  # override /etc/v2ray/config.json
  cat >/etc/v2ray/config.json <<_EOF_
{
  "log" : {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "port": 10000,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 64
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/w",
          "headers": {
            "Host": "$SITE"
          }
        }
      }
    }, 
    {
      "port": 11000,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 64
          }
        ]
      },
      "streamSettings": {
        "network": "h2",
        "security": "tls",
        "httpSettings": {
          "path": "/h",
          "host": ["$SITE"]
        },
        "tlsSettings": {
          "serverName": "$SITE",
          "certificates": [
            {
              "certificateFile": "/etc/v2ray/v2ray.crt",
              "keyFile": "/etc/v2ray/v2ray.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
_EOF_

  CADDY_CRT="/etc/ssl/caddy/acme/acme-v02.api.letsencrypt.org/sites/$SITE/$SITE.crt"
  CADDY_KEY="/etc/ssl/caddy/acme/acme-v02.api.letsencrypt.org/sites/$SITE/$SITE.key"

  # need to wait caddy to get the ssl certificate 
  while [ \( ! -f "$CADDY_CRT" \) -o \( ! -f "$CADDY_KEY" \)  ]
  do
    sleep 10
    echo 'Waiting Caddy certificate and key...'
  done

  # just link in to look nicer
  ln -s "$CADDY_CRT" /etc/v2ray/v2ray.crt
  ln -s "$CADDY_KEY" /etc/v2ray/v2ray.key

  # test the config file that just made
  /usr/bin/v2ray/v2ray --test --config /etc/v2ray/config.json

  # enabling the v2ray service
  systemctl restart v2ray
  systemctl enable v2ray

  # create client config file
  cat >"$ORI_USER_HOME/client_config.json" <<_EOF_
{
  "dns" : {
    "servers" : [
      "localhost"
    ]
  },
  "inbounds" : [
    {
      "listen" : "127.0.0.1",
      "port" : 1081,
      "protocol" : "socks",
      "tag" : "socksinbound",
      "settings" : {
        "auth" : "noauth",
        "udp" : false,
        "ip" : "127.0.0.1"
      }
    },
    {
      "listen" : "127.0.0.1",
      "port" : 8001,
      "protocol" : "http",
      "tag" : "httpinbound",
      "settings" : {
        "timeout" : 0
      }
    }
  ],
  "outbounds" : [
    {
      "tag" : "direct",
      "protocol" : "freedom",
      "settings" : {

      }
    },
    {
      "sendThrough" : "0.0.0.0",
      "mux" : {
        "enabled" : false,
        "concurrency" : 8
      },
      "protocol" : "vmess",
      "settings" : {
        "vnext" : [
          {
            "address" : "$SITE",
            "users" : [
              {
                "id" : "$UUID",
                "alterId" : 64,
                "security" : "auto",
                "level" : 0
              }
            ],
            "port" : 443
          }
        ]
      },
      "tag" : "ws",
      "streamSettings" : {
        "tlsSettings" : {
          "serverName" : "$SITE"
        },
        "network" : "ws",
        "security" : "tls",
        "wsSettings" : {
          "path" : "/w",
          "headers" : {
            "Host" : "$SITE"
          }
        }
      }
    },
    {
      "sendThrough" : "0.0.0.0",
      "mux" : {
        "enabled" : false,
        "concurrency" : 8
      },
      "protocol" : "vmess",
      "settings" : {
        "vnext" : [
          {
            "address" : "$SITE",
            "users" : [
              {
                "id" : "$UUID",
                "alterId" : 64,
                "security" : "auto",
                "level" : 0
              }
            ],
            "port" : 443
          }
        ]
      },
      "tag" : "h2",
      "streamSettings" : {
        "tlsSettings" : {
          "serverName" : "$SITE"
        },
        "httpSettings" : {
          "path" : "/h",
          "host" : [
            "$SITE"
          ]
        },
        "security" : "tls",
        "network" : "http"
      }
    }
  ],
  "routing" : {
    "name" : "bypasscn_private_apple",
    "domainStrategy" : "IPIfNonMatch",
    "rules" : [
      {
        "type" : "field",
        "outboundTag" : "direct",
        "domain" : [
          "localhost",
          "domain:me.com",
          "domain:lookup-api.apple.com",
          "domain:icloud-content.com",
          "domain:icloud.com",
          "domain:cdn-apple.com",
          "domain:apple-cloudkit.com",
          "domain:apple.com",
          "domain:apple.co",
          "domain:aaplimg.com",
          "domain:guzzoni.apple.com",
          "geosite:cn"
        ]
      },
      {
        "type" : "field",
        "outboundTag" : "direct",
        "ip" : [
          "geoip:private",
          "geoip:cn"
        ]
      },
      {
        "type" : "field",
        "outboundTag" : "h2",
        "port" : "0-65535"
      }
    ]
  },
  "log" : {
    "loglevel" : "info"
  }
}
_EOF_
}

# verify configuration values
verify_config() {
  SITE="$PARAM_SITE"
  DOMAIN="$PARAM_DOMAIN"
  if [ -z "$SITE" ] && [ -z "$DOMAIN" ]; then
    _exiterr 'No Site or Somain specified. Either of those should be declared.'
  # only specified DOMAIN
  elif [[ -z "$SITE" ]]; then
    SITE="$(hostname).$DOMAIN"
    echo "Only Domain $DOMAIN is presented. Automatically use $(hostname).$DOMAIN as Cloudflare site."
  # only specified SITE
  elif [[ -z "$DOMAIN" ]]; then
    echo "Only Site is presented. Auto detect domain and use it as Cloudflare domain."
    DOMAIN="$(echo "$SITE" | awk -F. '{ print ( $(NF-1)"."$(NF) ) }')"
  fi

  CF_EMAIL="$PARAM_CF_EMAIL"
  CF_KEY="$PARAM_CF_KEY"

  if [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
    _exiterr 'No CDN email or API Key passed. Both of those should be declared.'
  fi

  CERT_EMAIL="${PARAM_CERT_EMAIL:-notinuse@$DOMAIN}"
}

print_config(){
  echo "Site : $SITE"
  echo "Domain : $DOMAIN"
  echo "Cloudflare Email : $CF_EMAIL"
  echo "Cloudflare API Key : $CF_KEY"
  echo "Certificate Email : $CERT_EMAIL"
}

run(){
  verify_config
  print_config
  update_dns_record
  setup_caddy
  setup_v2ray
}

test_env_vars(){
  local VARS=$(grep -E -e '^[[:space:]]*# PARAM_Environment:' "${0}" | \
    sed -e 's/.*# PARAM_Environment: \(.*\)/\1/g' \
      -e '/N\/A/ d' | \
    tr '\n' ' ')
  for VAR in $VARS
  do
    if [ -n "${!VAR}" ]; then
      return 0
    fi
  done
  return 1
}

## see following code from https://github.com/lukas2511/dehydrated dehydrated file
_exiterr() {
  echo "ERROR: ${1}" >&2
  exit 1
}

# PARAM_Usage: --help (-h)
# PARAM_Environment: N/A
# PARAM_Description: Show help text and exit 
command_help() {
  printf "Usage: %s [-h] [parameter [argument]] [parameter [argument]] ...\n" "${0}"
  printf -- "\nParameters:\n"
  grep -E -e '^[[:space:]]*# PARAM_Usage:' \
    -e '^[[:space:]]*# PARAM_Description:' \
    -e '^[[:space:]]*# PARAM_Environment:' "${0}" | \
  while read -r usage; read -r env; read -r description; do
    if [[ ! "${usage}" =~ Usage ]] || \
      [[ ! "${description}" =~ Description ]] || \
      [[ ! "${env}" =~ Environment ]]; then
      _exiterr "Error generating help text."
    fi
    printf " %-28s ENV: %-18s %s\n" \
      "${usage##"# PARAM_Usage: "}" \
      "${env##"# PARAM_Environment: "}" \
      "${description##"# PARAM_Description: "}"
  done
}

main() {
  check_parameters() {
    if [[ -z "${1:-}" ]]; then
      echo "The specified command requires additional parameters. See help:" >&2
      echo >&2
      command_help >&2
      exit 1
    elif [[ "${1:0:1}" = "-" ]]; then
      _exiterr "Invalid argument: ${1}"
    fi
  }

  if [[ -n "${@}" ]] ; then
    while (( ${#} )); do
      case "${1}" in
        --help|-h)
          command_help
          exit 0
          ;;

        # PARAM_Usage: --domain (-d) domain.tld
        # PARAM_Environment: PARAM_DOMAIN
        # PARAM_Description: Use specified domain name
        --domain|-d)
          shift 1
          check_parameters "${1:-}"
          [[ -n "${PARAM_DOMAIN:-}" ]] && _exiterr "Domain can only be specified once!"
          PARAM_DOMAIN="${1}"
          ;;

        # PARAM_Usage: --site (-s) site.domain.tld
        # PARAM_Environment: PARAM_SITE
        # PARAM_Description: Use specified site for tls
        --site|-s)
          shift 1
          check_parameters "${1:-}"
          [[ -n "${PARAM_SITE:-}" ]] && _exiterr "Site can only be specified once!"
          PARAM_SITE="${1}"
          ;;

        # PARAM_Usage: --cf-email (-e) email
        # PARAM_Environment: PARAM_CF_EMAIL
        # PARAM_Description: Use specified email as Cloudflare account
        --cf-email|-e)
          shift 1
          check_parameters "${1:-}"
          [[ -n "${PARAM_CF_EMAIL:-}" ]] && _exiterr "Cloudflare email can only be specified once!"
          PARAM_CF_EMAIL="${1}"
          ;;

        # PARAM_Usage: --cf-key (-k) key
        # PARAM_Environment: PARAM_CF_KEY
        # PARAM_Description: Use specified key as Cloudflare API key
        --cf-key|-k)
          shift 1
          check_parameters "${1:-}"
          [[ -n "${PARAM_CF_KEY:-}" ]] && _exiterr "Cloudflare API key can only be specified once!"
          PARAM_CF_KEY="${1}"
          ;;

        # PARAM_Usage: --cert-email (-ce) email
        # PARAM_Environment: PARAM_CERT_EMAIL
        # PARAM_Description: Use specified email as letsencrypt account email
        --cert-email|-ce)
          shift 1
          check_parameters "${1:-}"
          [[ -n "${PARAM_CERT_EMAIL:-}" ]] && _exiterr "Certificate email can only be specified once!"
          PARAM_CERT_EMAIL="${1}"
          ;;

        *)
          echo "Unknown parameter detected: ${1}" >&2
          echo >&2
          command_help >&2
          exit 1
          ;;
      esac

      shift 1
    done
  else
    test_env_vars || command_help >&2
  fi

  run
}

main "${@:-}"

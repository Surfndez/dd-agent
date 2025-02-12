#!/bin/bash
# (C) Datadog, Inc. 2010-2016
# All rights reserved
# Licensed under Simplified BSD License (see LICENSE)
# Datadog Agent installation script: install and set up the Agent on supported Linux distributions
# using the package manager and Datadog repositories.

set -e
logfile="ddagent-install.log"
gist_request=/tmp/agent-gist-request.tmp
gist_response=/tmp/agent-gist-response.tmp

if [ $(command -v curl) ]; then
    dl_cmd="curl -f"
else
    dl_cmd="wget --quiet"
fi

# Set up a named pipe for logging
npipe=/tmp/$$.tmp
mknod $npipe p

# Log all output to a log for error checking
tee <$npipe $logfile &
exec 1>&-
exec 1>$npipe 2>&1
trap "rm -f $npipe" EXIT


function on_error() {
    printf "\033[31m$ERROR_MESSAGE
It looks like you hit an issue when trying to install the Agent.

Troubleshooting and basic usage information for the Agent are available at:

    http://docs.datadoghq.com/guides/basic_agent_usage/

If you're still having problems, please send an email to support@datadoghq.com
with the contents of ddagent-install.log and we'll do our very best to help you
solve your problem.\n\033[0m\n"
}
trap on_error ERR

function remove_rpm_gpg_keys() {
    local sudo_cmd="$1"
    shift
    local old_keys=("$@")
    for key in "${old_keys[@]}"; do
        if $sudo_cmd rpm -q "$key" 1>/dev/null 2>/dev/null; then
            echo -e "\033[34m\nRemoving old RPM key $key from the RPM database\n\033[0m"
            $sudo_cmd rpm --erase "$key"
        fi
    done
}
# list of old signing keys to remove
RPM_GPG_KEYS_TO_REMOVE=("gpg-pubkey-4172a230-55dd14f6")

if [ -n "$DD_HOSTNAME" ]; then
    dd_hostname=$DD_HOSTNAME
fi

if [ -n "$DD_API_KEY" ]; then
    apikey=$DD_API_KEY
fi

if [ -n "$DD_INSTALL_ONLY" ]; then
    no_start=true
else
    no_start=false
fi

if [ -n "$DD_HOST_TAGS" ]; then
    host_tags=$DD_HOST_TAGS
fi

if [ -n "$DD_PKG_LIST" ]; then
  pkg_list=$DD_PKG_LIST
else
  pkg_list="datadog-agent datadog-signing-keys"
fi

if [ -n "$DD_KEYS_URL" ]; then
  keys_url=$DD_KEYS_URL
else
  keys_url="keys.datadoghq.com"
fi

if [ ! $apikey ]; then
    printf "\033[31mAPI key not available in DD_API_KEY environment variable.\033[0m\n"
    exit 1;
fi

# DATADOG_APT_KEY_CURRENT.public always contains key used to sign current
# repodata and newly released packages
# DATADOG_APT_KEY_382E94DE.public expires in 2022
# DATADOG_APT_KEY_F14F620E.public expires in 2032
APT_GPG_KEYS=("DATADOG_APT_KEY_CURRENT.public" "DATADOG_APT_KEY_F14F620E.public" "DATADOG_APT_KEY_382E94DE.public")

# OS/Distro Detection
# Try lsb_release, fallback with /etc/issue then uname command
KNOWN_DISTRIBUTION="(Debian|Ubuntu|RedHat|CentOS|openSUSE|Amazon|Arista|SUSE)"
DISTRIBUTION=$(lsb_release -d 2>/dev/null | grep -Eo $KNOWN_DISTRIBUTION  || grep -Eo $KNOWN_DISTRIBUTION /etc/issue 2>/dev/null || grep -Eo $KNOWN_DISTRIBUTION /etc/Eos-release 2>/dev/null || grep -m1 -Eo $KNOWN_DISTRIBUTION /etc/os-release 2>/dev/null || uname -s)

if [ $DISTRIBUTION = "Darwin" ]; then
    printf "\033[31mThis script does not support installing on the Mac.

Please use the 1-step script available at https://app.datadoghq.com/account/settings#agent/mac.\033[0m\n"
    exit 1;

elif [ -f /etc/debian_version -o "$DISTRIBUTION" == "Debian" -o "$DISTRIBUTION" == "Ubuntu" ]; then
    OS="Debian"
elif [ -f /etc/redhat-release -o "$DISTRIBUTION" == "RedHat" -o "$DISTRIBUTION" == "CentOS" -o "$DISTRIBUTION" == "Amazon" ]; then
    OS="RedHat"
# Some newer distros like Amazon may not have a redhat-release file
elif [ -f /etc/system-release -o "$DISTRIBUTION" == "Amazon" ]; then
    OS="RedHat"
# Arista is based off of Fedora14/18 but do not have /etc/redhat-release
elif [ -f /etc/Eos-release -o "$DISTRIBUTION" == "Arista" ]; then
    OS="RedHat"
# openSUSE and SUSE use /etc/SuSE-release
elif [ -f /etc/SuSE-release -o "$DISTRIBUTION" == "SUSE" -o "$DISTRIBUTION" == "openSUSE" ]; then
    OS="SUSE"
fi

# Root user detection
if [ $(echo "$UID") = "0" ]; then
    sudo_cmd=''
else
    sudo_cmd='sudo'
fi

DDBASE=false
# Python Detection
has_python=$(which python || echo "no")
if [ "$has_python" != "no" ]; then
    PY_VERSION=$(python -c 'import sys; print("{0}.{1}".format(sys.version_info[0], sys.version_info[1]))' 2>/dev/null || echo "TOO OLD")
    if [ "$PY_VERSION" = "TOO OLD" ]; then
        DDBASE=true
    fi
fi

# Install the necessary package sources
if [ $OS = "RedHat" ]; then
    remove_rpm_gpg_keys "$sudo_cmd" "${RPM_GPG_KEYS_TO_REMOVE[@]}"

    echo -e "\033[34m\n* Installing YUM sources for Datadog\n\033[0m"

    UNAME_M=$(uname -m)
    if [ "$UNAME_M"  == "i686" -o "$UNAME_M"  == "i386" -o "$UNAME_M"  == "x86" ]; then
        ARCHI="i386"
    else
        ARCHI="x86_64"
    fi

    # Versions of yum on RedHat 5 and lower embed M2Crypto with SSL that doesn't support TLS1.2
    if [ -f /etc/redhat-release ]; then
        REDHAT_MAJOR_VERSION=$(grep -Eo "[0-9].[0-9]{1,2}" /etc/redhat-release | head -c 1)
    fi
    if [ -n "$REDHAT_MAJOR_VERSION" ] && [ "$REDHAT_MAJOR_VERSION" -le "5" ]; then
        PROTOCOL="http"
    else
        PROTOCOL="https"
    fi

    $sudo_cmd sh -c "echo -e '[datadog]\nname = Datadog, Inc.\nbaseurl = $PROTOCOL://yum.datadoghq.com/rpm/$ARCHI/\nenabled=1\ngpgcheck=1\npriority=1\ngpgkey=$PROTOCOL://${keys_url}/DATADOG_RPM_KEY_CURRENT.public\n       $PROTOCOL://${keys_url}/DATADOG_RPM_KEY_FD4BF915.public' > /etc/yum.repos.d/datadog.repo"

    printf "\033[34m* Installing the Datadog Agent package\n\033[0m\n"

    if $DDBASE; then
        DD_BASE_INSTALLED=$(yum list installed datadog-agent-base > /dev/null 2>&1 || echo "no")
        if [ "$DD_BASE_INSTALLED" != "no" ]; then
            echo -e "\033[34m\n* Uninstall datadog-agent-base\n\033[0m"
            $sudo_cmd yum -y remove datadog-agent-base
        fi
    fi
    $sudo_cmd yum -y --disablerepo='*' --enablerepo='datadog' install datadog-agent || $sudo_cmd yum -y install datadog-agent
elif [ $OS = "Debian" ]; then
    apt_trusted_d_keyring="/etc/apt/trusted.gpg.d/datadog-archive-keyring.gpg"
    apt_usr_share_keyring="/usr/share/keyrings/datadog-archive-keyring.gpg"

    printf "\033[34m\n* Installing apt-transport-https, curl and gnupg\n\033[0m\n"
    $sudo_cmd apt-get update || printf "\033[31m'apt-get update' failed, the script will not install the latest version of apt-transport-https.\033[0m\n"
    # installing curl might trigger install of additional version of libssl; this will fail the installation process,
    # see https://unix.stackexchange.com/q/146283 for reference - we use DEBIAN_FRONTEND=noninteractive to fix that
    if [ -z "$sudo_cmd" ]; then
        # if $sudo_cmd is empty, doing `$sudo_cmd X=Y command` fails with
        # `X=Y: command not found`; therefore we don't prefix the command with
        # $sudo_cmd at all in this case
        DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https curl gnupg
    else
        $sudo_cmd DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https curl gnupg
    fi
    printf "\033[34m\n* Installing APT package sources for Datadog\n\033[0m\n"
    $sudo_cmd sh -c "echo 'deb [signed-by=${apt_usr_share_keyring}] https://apt.datadoghq.com/ stable main' > /etc/apt/sources.list.d/datadog.list"

    if [ ! -f $apt_usr_share_keyring ]; then
        $sudo_cmd touch $apt_usr_share_keyring
    fi
    # ensure that the _apt user used on Ubuntu/Debian systems to read GPG keyrings
    # can read our keyring
    $sudo_cmd chmod a+r $apt_usr_share_keyring

    for key in "${APT_GPG_KEYS[@]}"; do
        $sudo_cmd curl --retry 5 -o "/tmp/${key}" "https://${keys_url}/${key}"
        $sudo_cmd cat "/tmp/${key}" | $sudo_cmd gpg --import --batch --no-default-keyring --keyring "$apt_usr_share_keyring"
    done

    release_version="$(grep VERSION_ID /etc/os-release | cut -d = -f 2 | xargs echo | cut -d "." -f 1)"
    if { [ "$DISTRIBUTION" == "Debian" ] && [ "$release_version" -lt 9 ]; } || \
       { [ "$DISTRIBUTION" == "Ubuntu" ] && [ "$release_version" -lt 16 ]; }; then
        # copy with -a to preserve file permissions
        $sudo_cmd cp -a $apt_usr_share_keyring $apt_trusted_d_keyring
    fi

    printf "\033[34m\n* Installing the Datadog Agent package\n\033[0m\n"
    ERROR_MESSAGE="ERROR
Failed to update the sources after adding the Datadog repository.
This may be due to any of the configured APT sources failing -
see the logs above to determine the cause.
If the failing repository is Datadog, please contact Datadog support.
*****
"
    $sudo_cmd apt-get update -o Dir::Etc::sourcelist="sources.list.d/datadog.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
    ERROR_MESSAGE="ERROR
Failed to install the Datadog package, sometimes it may be
due to another APT source failing. See the logs above to
determine the cause.
If the cause is unclear, please contact Datadog support.
*****
"
    $sudo_cmd apt-get install -y --force-yes $pkg_list
    ERROR_MESSAGE=""
elif [ $OS = "SUSE" ]; then
  remove_rpm_gpg_keys "$sudo_cmd" "${RPM_GPG_KEYS_TO_REMOVE[@]}"

  UNAME_M=$(uname -m)
  if [ "$UNAME_M"  == "i686" -o "$UNAME_M"  == "i386" -o "$UNAME_M"  == "x86" ]; then
      printf "\033[31mThe Datadog Agent installer is only available for 64 bit SUSE Enterprise machines.\033[0m\n"
      exit;
  fi

  echo -e "\033[34m\n* Installing YUM Repository for Datadog\n\033[0m"
  $sudo_cmd sh -c "echo -e '[datadog]\nname=datadog\nenabled=1\nbaseurl=https://yum.datadoghq.com/suse/rpm/x86_64\ntype=rpm-md\ngpgcheck=1\nrepo_gpgcheck=0\ngpgkey=https://${keys_url}/DATADOG_RPM_KEY_CURRENT.public' > /etc/zypp/repos.d/datadog.repo"

  echo -e "\033[34m\n* Importing the Datadog GPG Keys\n\033[0m"
  $sudo_cmd rpm --import https://${keys_url}/DATADOG_RPM_KEY_CURRENT.public
  $sudo_cmd rpm --import https://${keys_url}/DATADOG_RPM_KEY_FD4BF915.public

  echo -e "\033[34m\n* Refreshing repositories\n\033[0m"
  $sudo_cmd zypper --non-interactive --no-gpg-check refresh datadog

  echo -e "\033[34m\n* Installing Datadog Agent\n\033[0m"
  $sudo_cmd zypper --non-interactive install datadog-agent

else
    printf "\033[31mYour OS or distribution are not supported by this install script.
Please follow the instructions on the Agent setup page:

    https://app.datadoghq.com/account/settings#agent\033[0m\n"
    exit;
fi

# Set the configuration
if [ -e /etc/dd-agent/datadog.conf ]; then
    printf "\033[34m\n* Keeping old datadog.conf configuration file\n\033[0m\n"
else
    printf "\033[34m\n* Adding your API key to the Agent configuration: /etc/dd-agent/datadog.conf\n\033[0m\n"
    $sudo_cmd sh -c "sed 's/api_key:.*/api_key: $apikey/' /etc/dd-agent/datadog.conf.example > /etc/dd-agent/datadog.conf"
    if [ $dd_hostname ]; then
        printf "\033[34m\n* Adding your HOSTNAME to the Agent configuration: /etc/dd-agent/datadog.conf\n\033[0m\n"
        $sudo_cmd sh -c "sed -i 's/# hostname:.*/hostname: $dd_hostname/' /etc/dd-agent/datadog.conf"
    fi
    if [ $host_tags ]; then
        printf "\033[34m\n* Adding your HOST TAGS to the Agent configuraton: /etc/dd-agent/datadog.conf\n\033[0m\n"
        $sudo_cmd sh -c "sed -i 's/# tags:.*/tags: $host_tags/' /etc/dd-agent/datadog.conf"
    fi
    $sudo_cmd chown dd-agent:dd-agent /etc/dd-agent/datadog.conf
    $sudo_cmd chmod 640 /etc/dd-agent/datadog.conf
fi

restart_cmd="$sudo_cmd /etc/init.d/datadog-agent restart"
if command -v invoke-rc.d >/dev/null 2>&1; then
    restart_cmd="$sudo_cmd invoke-rc.d datadog-agent restart"
fi

if $no_start; then
    printf "\033[34m
* DD_INSTALL_ONLY environment variable set: the newly installed version of the agent
will not start by itself. You will have to do it manually using the following
command:

    $restart_cmd

\033[0m\n"
    exit
fi

printf "\033[34m* Starting the Agent...\n\033[0m\n"
eval $restart_cmd

# Wait for metrics to be submitted by the forwarder
printf "\033[32m
Your Agent has started up for the first time. We're currently verifying that
data is being submitted. You should see your Agent show up in Datadog shortly
at:

    https://app.datadoghq.com/infrastructure\033[0m

Waiting for metrics..."

c=0
while [ "$c" -lt "30" ]; do
    sleep 1
    echo -n "."
    c=$(($c+1))
done

# Reuse the same counter
c=0

# The command to check the status of the forwarder might fail at first, this is expected
# so we remove the trap and we set +e
set +e
trap - ERR

$dl_cmd http://127.0.0.1:17123/status?threshold=0 > /dev/null 2>&1
success=$?
while [ "$success" -gt "0" ]; do
    sleep 1
    echo -n "."
    $dl_cmd http://127.0.0.1:17123/status?threshold=0 > /dev/null 2>&1
    success=$?
    c=$(($c+1))

    if [ "$c" -gt "15" -o "$success" -eq "0" ]; then
        # After 15 tries, we give up, we restore the trap and set -e
        # Also restore the trap on success
        set -e
        trap on_error ERR
    fi
done

# Metrics are submitted, echo some instructions and exit
printf "\033[32m

Your Agent is running and functioning properly. It will continue to run in the
background and submit metrics to Datadog.

If you ever want to stop the Agent, run:

    sudo /etc/init.d/datadog-agent stop

And to run it again run:

    sudo /etc/init.d/datadog-agent start

\033[0m"

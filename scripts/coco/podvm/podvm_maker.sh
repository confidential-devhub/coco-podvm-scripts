#! /bin/bash

dnf config-manager --add-repo=https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/ && dnf install -y --nogpgcheck afterburn && dnf clean all && dnf config-manager --set-disabled "*centos*"
cat <<EOF > /etc/systemd/system/afterburn-checkin.service
[Unit]
ConditionKernelCommandLine=

[Service]
ExecStart=
ExecStart=-/usr/bin/afterburn --provider=azure --check-in
EOF
ln -s ../afterburn-checkin.service /etc/systemd/system/multi-user.target.wants/afterburn-checkin.service

tar -xzvf /tmp/podvm-binaries.tar.gz -C /
tar -xzvf /tmp/pause-bundle.tar.gz -C /

# fixes a failure of the podns@netns service
semanage fcontext -a -t bin_t /usr/sbin/ip && restorecon -v /usr/sbin/ip

# remove the /kata-containers bind mount, otherwise, agent will fail to create
# container's overlay fs on top of the / (/kata-containers) overlay (created by
# systemd.volatile
rm /etc/systemd/system/run-kata\\x2dcontainers.mount
mkdir /run/kata-containers

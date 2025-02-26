# node


### AutoUpdates + Running as a systemd service

```
cat <<EOT > /etc/systemd/system.conf
[Manager]
DefaultTasksMax=infinity
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
DefaultLimitLOCKS=infinity
EOT
cat <<EOT > /etc/systemd/user.conf
[Manager]
DefaultTasksMax=infinity
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
DefaultLimitLOCKS=infinity
EOT


cat <<EOT > /etc/systemd/system/amadeusd.service
[Unit]
Description=AmadeusD
After=network-online.target

[Service]
Type=forking
LimitNOFILE=1048576
KillMode=control-group
Restart=always
RestartSec=3
User=root
WorkingDirectory=/root/
Environment="AUTOUPDATE=true"
ExecStart=/usr/bin/screen -UdmS amadeusd bash -c './amadeusd'

[Install]
WantedBy=default.target
EOT

systemctl enable amadeusd
systemctl start amadeusd

screen -rd amadeusd
```

```
For computer autostart
Environment="COMPUTOR=true"

For computer autostart to be validator
Environment="COMPUTOR=trainer"
```
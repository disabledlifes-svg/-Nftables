chatgpt plus搓的

chmod +x /root/nftables-manager

bash /root/nftables-manager

systemctl daemon-reload
systemctl enable nft-manager.service
systemctl restart nft-manager.service
systemctl status nft-manager.service

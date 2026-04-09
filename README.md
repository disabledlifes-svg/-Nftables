chatgpt plus搓的

sudo apt update
sudo apt install -y nftables curl

sudo curl -fsSL -o /root/nft-manager.sh \ https://raw.githubusercontent.com/disabledlifes-svg/self-nftables/refs/heads/main/nft-manager.sh

chmod +x /root/nft-manager.sh

bash /root/nft-manager.sh

systemctl daemon-reload
systemctl enable nft-manager.service
systemctl restart nft-manager.service
systemctl status nft-manager.service

常用的命令
sudo /root/nft-manager.sh status
sudo /root/nft-manager.sh open-list
sudo /root/nft-manager.sh forward-list
sudo /root/nft-manager.sh preview
sudo nft -c -f /etc/nft_manager/rules.preview.nft
sudo /root/nft-manager.sh apply
sudo /root/nft-manager.sh rollback
sudo systemctl status nft-manager.service --no-pager

紧急恢复
sudo /root/nft-manager.sh rollback

完全清空运行态规则
sudo nft flush ruleset

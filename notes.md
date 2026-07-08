# 个人自用脚本库，感谢yahuisme大佬的原始脚本，我个人增加了的sni校验和防火墙设置，以及修正了密钥对的解析错误。

## Proxy Installer
```
wget https://github.com/iPixelOldC/Scripts/raw/refs/heads/main/vlesswithss.sh
```
```
bash <(curl -L https://github.com/iPixelOldC/Scripts/raw/refs/heads/main/vlesswithss.sh)
```
```
bash <(curl -L https://github.com/iPixelOldC/Scripts/raw/refs/heads/main/vlesswithss-nosni-fw.sh)
```
> Note：nosni那个要手动管理防火墙

## SSH Key Installer
```
bash <(curl -fsSL https://raw.githubusercontent.com/iPixelOldC/Scripts/refs/heads/main/key.sh) -g iPixelOldC -d
```
```
bash <(curl -fsSL https://raw.githubusercontent.com/iPixelOldC/Scripts/refs/heads/main/key.sh) -c iPixelOldC -d
```

- -o - Overwrite mode, this option is valid at the top
- -g - Get the public key from GitHub, the arguments is the GitHub ID
- -c - Get the public key from CodeBerg, the arguments is the CodeBerg ID
- -u - Get the public key from the URL, the arguments is the URL
- -f - Get the public key from the local file, the arguments is the local file path
- -p - Change SSH port, the arguments is port number
- -d - Disable password login

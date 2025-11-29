#!/bin/bash
echo "=== 诊断 SecureProxy Python 文件 ==="
echo ""

echo "1. 创建目标目录: ~/Library/Application\ Support/SecureProxy/python/"
mkdir -p ~/Library/Application\ Support/SecureProxy/python/
echo ""

echo "2. 复制当前目录下的Python文件到目标目录"
cp client.py ~/Library/Application\ Support/SecureProxy/python/
cp crypto.py ~/Library/Application\ Support/SecureProxy/python/
cp tls_fingerprint.py ~/Library/Application\ Support/SecureProxy/python/
echo "✅ 复制: client.py 从 client.py"
echo "✅ 复制: crypto.py 从 crypto.py"
echo "✅ 复制: tls_fingerprint.py 从 tls_fingerprint.py"
echo "复制完成: 3/3 个文件"
echo ""

echo "3. 查看目标目录中的文件:"
ls -la ~/Library/Application\ Support/SecureProxy/python/
echo ""

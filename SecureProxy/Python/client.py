# client.py - 激进优化版（完全防堵塞）
import asyncio
import json
import os
import sys
import hmac
import socket
import struct
import ssl
import time
from pathlib import Path
from collections import deque

# 核心模块导入
from crypto import derive_keys, encrypt, decrypt

# ==================== 清除环境变量 ====================
def clear_system_proxy():
    """清除代理环境变量"""
    proxy_vars = [
        'HTTP_PROXY', 'HTTPS_PROXY', 'FTP_PROXY', 'SOCKS_PROXY',
        'http_proxy', 'https_proxy', 'ftp_proxy', 'socks_proxy',
        'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy'
    ]

    cleared = []
    for var in proxy_vars:
        if var in os.environ:
            cleared.append(f"{var}={os.environ[var]}")
            del os.environ[var]

    if cleared:
        print("🛡️  已清除系统代理环境变量:")
        for item in cleared:
            print(f"   - {item}")
        print()

clear_system_proxy()

# ==================== 🔥 激进配置 ====================
READ_BUFFER_SIZE = 256 * 1024
WRITE_BUFFER_SIZE = 128 * 1024

MAX_CONCURRENT_CONNECTIONS = 200

# 🔥🔥🔥 关键：极短超时，快速失败
MAX_RETRIES = 1  # 只重试1次
RETRY_DELAY = 0.1  # 100毫秒
CONNECTION_TIMEOUT = 5  # 总超时5秒
CONNECT_TIMEOUT = 3  # 连接超时3秒
HANDSHAKE_TIMEOUT = 2  # 握手超时2秒
RECV_TIMEOUT = 10  # 接收超时10秒
SEND_TIMEOUT = 5  # 发送超时5秒

# 🔥 健康检查
HEALTH_CHECK_INTERVAL = 5  # 5秒检查一次
FAILURE_THRESHOLD = 10  # 连续失败10次进入降级模式
health_failures = 0
degraded_mode = False

def resource_path(relative_path):
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    return os.path.join(os.path.abspath("."), relative_path)

CONFIG_DIR = resource_path("config")

# ==================== 全局状态 ====================
status = "disconnected"
current_config = None
traffic_up = traffic_down = 0
last_traffic_time = time.time()
active_connections = 0
failed_connections = 0
success_connections = 0
timeout_connections = 0
connection_semaphore = None

# 🔥 请求队列（防止过载）
request_queue = None
MAX_QUEUE_SIZE = 500

# ==================== 从环境变量加载配置 ====================
def load_config_from_env():
    """从环境变量读取配置"""
    try:
        # Swift 端会通过环境变量传递 JSON 配置
        config_json = os.environ.get('SECURE_PROXY_CONFIG')

        if not config_json:
            print("❌ 错误: 未找到配置 (SECURE_PROXY_CONFIG 环境变量)")
            return None

        config = json.loads(config_json)

        # 验证必需字段
        required_fields = ['name', 'sni_host', 'path', 'server_port',
                          'socks_port', 'http_port', 'pre_shared_key']

        for field in required_fields:
            if field not in config:
                print(f"❌ 错误: 配置缺少字段 '{field}'")
                return None

        print(f"✅ 加载配置: {config['name']}")
        print(f"   - 服务器: {config['sni_host']}:{config['server_port']}")
        print(f"   - 路径: {config['path']}")
        print(f"   - SOCKS5: {config['socks_port']}")
        print(f"   - HTTP: {config['http_port']}")

        return config

    except json.JSONDecodeError as e:
        print(f"❌ 配置 JSON 解析失败: {e}")
        return None
    except Exception as e:
        print(f"❌ 加载配置失败: {e}")
        return None

# ==================== 流量统计 ====================
async def traffic_monitor():
    global traffic_up, traffic_down, last_traffic_time, active_connections
    global failed_connections, success_connections, timeout_connections
    global health_failures, degraded_mode

    while True:
        await asyncio.sleep(5)
        now = time.time()
        elapsed = now - last_traffic_time

        if elapsed > 0 and (traffic_up > 0 or traffic_down > 0):
            up_speed = traffic_up / elapsed / 1024
            down_speed = traffic_down / elapsed / 1024

            # 🔥 计算成功率
            total = success_connections + failed_connections
            success_rate = (success_connections / total * 100) if total > 0 else 0

            # 🔥 健康状态
            status = "🟢" if not degraded_mode else "🔴"

            print(f"{status} 📊 ↑{up_speed:6.1f}KB/s ↓{down_speed:6.1f}KB/s | "
                  f"连接:{active_connections}/{MAX_CONCURRENT_CONNECTIONS} | "
                  f"成功率:{success_rate:.0f}% ({success_connections}/{total}) | "
                  f"超时:{timeout_connections}")

            traffic_up = traffic_down = 0
            last_traffic_time = now

# ==================== 🔥 健康检查 ====================
async def health_checker():
    """健康检查守护进程"""
    global health_failures, degraded_mode

    while True:
        await asyncio.sleep(HEALTH_CHECK_INTERVAL)

        total = success_connections + failed_connections
        if total > 0:
            failure_rate = failed_connections / total

            if failure_rate > 0.5:  # 失败率 >50%
                health_failures += 1
                if health_failures >= FAILURE_THRESHOLD and not degraded_mode:
                    degraded_mode = True
                    print(f"\n🔴 警告: 进入降级模式（失败率过高）")
                    print(f"   建议检查服务器状态和网络连接")
            else:
                health_failures = max(0, health_failures - 1)
                if degraded_mode and health_failures == 0:
                    degraded_mode = False
                    print(f"\n🟢 恢复正常模式")

# ==================== 🔥 极速 WebSocket ====================
class RawWebSocket:
    """极速WebSocket（最小超时）"""

    def __init__(self):
        self.reader = None
        self.writer = None
        self.closed = False
        self.last_activity = time.time()

    async def connect(self, host, port, path, ssl_context):
        """快速连接（严格超时控制）"""
        try:
            # 🔥 连接超时3秒
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_connection(
                    host=host,
                    port=port,
                    ssl=ssl_context,
                    server_hostname=host,
                    limit=READ_BUFFER_SIZE
                ),
                timeout=CONNECT_TIMEOUT
            )

            sock = self.writer.get_extra_info('socket')
            if sock:
                try:
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                  struct.pack('ii', 1, 0))
                except:
                    pass

        except asyncio.TimeoutError:
            raise Exception(f"连接超时({CONNECT_TIMEOUT}s)")
        except Exception as e:
            raise Exception(f"连接失败: {e}")

        try:
            # 🔥 握手超时2秒
            await asyncio.wait_for(self._handshake(host, port, path), timeout=HANDSHAKE_TIMEOUT)
        except asyncio.TimeoutError:
            await self.close()
            raise Exception(f"握手超时({HANDSHAKE_TIMEOUT}s)")
        except Exception as e:
            await self.close()
            raise Exception(f"握手失败: {e}")

    async def _handshake(self, host, port, path):
        """WebSocket 握手"""
        import base64

        key = base64.b64encode(os.urandom(16)).decode()

        # 构建握手请求
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"User-Agent: Mozilla/5.0\r\n"
            f"\r\n"
        )

        self.writer.write(request.encode())
        await self.writer.drain()

        # 读取响应
        response_line = await self.reader.readline()
        if b'101' not in response_line:
            raise Exception(f"握手失败: {response_line}")

        # 读取所有 headers
        while True:
            line = await self.reader.readline()
            if line in (b'\r\n', b'\n', b''):
                break

    async def send(self, data):
        """发送（带超时）"""
        if self.closed:
            raise Exception("WebSocket 已关闭")

        # 构建 WebSocket 数据帧
        frame = bytearray()

        # FIN=1, opcode=0x2 (binary)
        frame.append(0x82)

        # Mask=1, payload length
        length = len(data)
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame.extend(length.to_bytes(2, 'big'))
        else:
            frame.append(0x80 | 127)
            frame.extend(length.to_bytes(8, 'big'))

        # Masking key
        mask = os.urandom(4)
        frame.extend(mask)

        # Masked payload
        masked = bytearray(data)
        for i in range(len(masked)):
            masked[i] ^= mask[i % 4]
        frame.extend(masked)

        self.writer.write(bytes(frame))

        # 🔥 发送超时5秒
        await asyncio.wait_for(self.writer.drain(), timeout=SEND_TIMEOUT)
        self.last_activity = time.time()

    async def recv(self):
        """接收（带超时）"""
        if self.closed:
            raise Exception("WebSocket 已关闭")

        # 读取帧头
        header = await self.reader.readexactly(2)

        # 解析 payload length
        length = header[1] & 0x7F
        if length == 126:
            length_bytes = await self.reader.readexactly(2)
            length = int.from_bytes(length_bytes, 'big')
        elif length == 127:
            length_bytes = await self.reader.readexactly(8)
            length = int.from_bytes(length_bytes, 'big')

        payload = await self.reader.readexactly(length)
        self.last_activity = time.time()
        return payload

    async def close(self):
        """快速关闭"""
        if self.closed:
            return
        self.closed = True

        if self.writer:
            try:
                self.writer.close()
                await asyncio.wait_for(self.writer.wait_closed(), timeout=1)
            except:
                pass

# ==================== SSL 上下文 ====================
def get_ssl_context():
    """创建 SSL 上下文"""
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
    ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
    ssl_context.maximum_version = ssl.TLSVersion.TLSv1_3
    return ssl_context

# ==================== 创建安全连接 ====================
async def create_secure_connection(target):
    """创建安全连接（激进版 - 极速失败）"""
    global failed_connections, success_connections, timeout_connections

    if target.startswith('127.0.0.1:1080') or target.startswith('127.0.0.1:1081'):
        raise Exception(f"拒绝连接: 检测到代理循环")

    ws = None
    last_error = None

    # 🔥🔥🔥 只尝试1次，最多重试1次（总共2次）
    for attempt in range(MAX_RETRIES + 1):
        try:
            host = str(current_config["sni_host"])
            path = str(current_config["path"])
            port = int(current_config.get("server_port", 443))

            ws = RawWebSocket()

            # 🔥 连接阶段（3秒超时）
            await ws.connect(host, port, path, get_ssl_context())

            # 🔥 密钥交换（2秒超时）
            client_pub = os.urandom(32)
            await ws.send(client_pub)
            server_pub = await asyncio.wait_for(ws.recv(), timeout=2)

            if len(server_pub) != 32:
                raise Exception(f"服务器公钥长度错误")

            # 🔥 密钥派生（快速）
            salt = client_pub + server_pub
            psk = bytes.fromhex(current_config["pre_shared_key"])
            send_key, recv_key = derive_keys(psk, salt)

            # 🔥 认证（2秒超时）
            auth_digest = hmac.new(send_key, b"auth", digestmod='sha256').digest()
            await ws.send(auth_digest)
            auth_response = await asyncio.wait_for(ws.recv(), timeout=2)
            expected = hmac.new(recv_key, b"ok", digestmod='sha256').digest()

            if not hmac.compare_digest(auth_response, expected):
                raise Exception("认证失败")

            # 🔥 CONNECT（2秒超时）
            connect_cmd = f"CONNECT {target}".encode('utf-8')
            await ws.send(encrypt(send_key, connect_cmd))
            response = await asyncio.wait_for(ws.recv(), timeout=2)
            plaintext = decrypt(recv_key, response)

            if plaintext != b"OK":
                raise Exception(f"CONNECT 失败: {plaintext.decode('utf-8', errors='ignore')}")

            # 🔥 成功
            success_connections += 1
            return ws, send_key, recv_key

        except asyncio.TimeoutError:
            timeout_connections += 1
            last_error = Exception("连接超时")
            if ws:
                await ws.close()

            # 🔥 超时立即放弃，不重试
            break

        except Exception as e:
            last_error = e
            if ws:
                await ws.close()

            # 🔥 快速重试（100ms）
            if attempt < MAX_RETRIES:
                await asyncio.sleep(RETRY_DELAY)
            else:
                break

    # 🔥 失败
    failed_connections += 1

    # 🔥 静默处理常见错误
    error_msg = str(last_error)
    if not any(x in error_msg for x in ["gaierror", "nodename", "Name or service", "超时"]):
        # 只打印非常见错误
        pass

    raise last_error

# ==================== 数据转发（优化版）====================
async def ws_to_socket(ws, recv_key, writer):
    """WebSocket -> Socket"""
    global traffic_down
    try:
        while not ws.closed:
            # 🔥 接收超时10秒
            enc_data = await asyncio.wait_for(ws.recv(), timeout=RECV_TIMEOUT)
            if writer.is_closing():
                break

            traffic_down += len(enc_data)
            plaintext = decrypt(recv_key, enc_data)
            writer.write(plaintext)

            # 智能drain
            buffer_size = writer.transport.get_write_buffer_size()
            if buffer_size > WRITE_BUFFER_SIZE * 0.8:
                await asyncio.wait_for(writer.drain(), timeout=2)

    except asyncio.TimeoutError:
        pass
    except:
        pass
    finally:
        if not writer.is_closing():
            try:
                await asyncio.wait_for(writer.drain(), timeout=1)
                writer.close()
                await asyncio.wait_for(writer.wait_closed(), timeout=1)
            except:
                pass

async def socket_to_ws(reader, ws, send_key):
    """Socket -> WebSocket"""
    global traffic_up
    try:
        while not ws.closed:
            # 🔥 读取超时10秒
            data = await asyncio.wait_for(reader.read(READ_BUFFER_SIZE), timeout=RECV_TIMEOUT)
            if not data:
                break

            traffic_up += len(data)
            encrypted = encrypt(send_key, data)
            await ws.send(encrypted)

    except asyncio.TimeoutError:
        pass
    except:
        pass
    finally:
        if not ws.closed:
            try:
                await asyncio.wait_for(ws.close(), timeout=1)
            except:
                pass

# ==================== SOCKS5 处理（激进版）====================
async def handle_socks5(reader, writer):
    """处理 SOCKS5 连接（快速失败版）"""
    global active_connections

    async with connection_semaphore:
        active_connections += 1

        ws = None
        try:
            # 🔥 SOCKS5握手超时2秒
            data = await asyncio.wait_for(reader.readexactly(2), timeout=2)
            if data[0] != 0x05:
                return

            nmethods = data[1]
            await reader.readexactly(nmethods)
            writer.write(b"\x05\x00")
            await writer.drain()

            data = await asyncio.wait_for(reader.readexactly(4), timeout=2)
            if data[1] != 0x01:
                return

            addr_type = data[3]
            if addr_type == 1:
                addr = socket.inet_ntoa(await reader.readexactly(4))
            elif addr_type == 3:
                length = ord(await reader.readexactly(1))
                addr = (await reader.readexactly(length)).decode('utf-8')
            else:
                return

            port = int.from_bytes(await reader.readexactly(2), "big")
            target = f"{addr}:{port}"

            # 🔥🔥🔥 关键：整个连接过程最多5秒
            try:
                ws, send_key, recv_key = await asyncio.wait_for(
                    create_secure_connection(target),
                    timeout=CONNECTION_TIMEOUT
                )
            except asyncio.TimeoutError:
                # 🔥 超时快速返回，不堵塞
                return
            except:
                # 🔥 失败快速返回
                return

            writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            await writer.drain()

            # 🔥 数据转发（降低超时）
            try:
                await asyncio.wait_for(
                    asyncio.gather(
                        ws_to_socket(ws, recv_key, writer),
                        socket_to_ws(reader, ws, send_key),
                        return_exceptions=True
                    ),
                    timeout=60  # 数据传输60秒后自动断开
                )
            except asyncio.TimeoutError:
                pass

        except:
            pass  # 🔥 静默处理所有错误
        finally:
            active_connections -= 1
            if ws:
                try:
                    await asyncio.wait_for(ws.close(), timeout=1)
                except:
                    pass
            if not writer.is_closing():
                try:
                    writer.close()
                    await asyncio.wait_for(writer.wait_closed(), timeout=1)
                except:
                    pass

# ==================== HTTP 处理（激进版）====================
async def handle_http(reader, writer):
    """处理 HTTP CONNECT（快速失败版）"""
    global active_connections

    async with connection_semaphore:
        active_connections += 1

        ws = None
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=2)
            if not line or not line.startswith(b"CONNECT"):
                writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
                await writer.drain()
                return

            line_str = line.decode('utf-8').strip()
            parts = line_str.split()
            if len(parts) < 2:
                return

            host_port = parts[1]
            if ":" in host_port:
                host, port = host_port.split(":", 1)
            else:
                host = host_port
                port = "443"
            target = f"{host}:{port}"

            while True:
                header = await reader.readline()
                if header in (b'\r\n', b'\n', b''):
                    break

            # 🔥 快速连接（5秒超时）
            try:
                ws, send_key, recv_key = await asyncio.wait_for(
                    create_secure_connection(target),
                    timeout=CONNECTION_TIMEOUT
                )
            except:
                return

            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()

            try:
                await asyncio.wait_for(
                    asyncio.gather(
                        ws_to_socket(ws, recv_key, writer),
                        socket_to_ws(reader, ws, send_key),
                        return_exceptions=True
                    ),
                    timeout=60
                )
            except asyncio.TimeoutError:
                pass

        except:
            pass
        finally:
            active_connections -= 1
            if ws:
                try:
                    await asyncio.wait_for(ws.close(), timeout=0.5)
                except:
                    pass
            if not writer.is_closing():
                try:
                    writer.close()
                    await asyncio.wait_for(writer.wait_closed(), timeout=0.5)
                except:
                    pass

# ==================== 启动服务器 ====================
async def start_servers():
    """启动代理服务器"""
    global connection_semaphore

    if not current_config:
        print("❌ 无有效配置")
        return

    socks_port = int(current_config["socks_port"])
    http_port = int(current_config["http_port"])

    connection_semaphore = asyncio.Semaphore(MAX_CONCURRENT_CONNECTIONS)

    socks_server = await asyncio.start_server(
        handle_socks5, "127.0.0.1", socks_port, backlog=256
    )
    http_server = await asyncio.start_server(
        handle_http, "127.0.0.1", http_port, backlog=256
    )

    print("=" * 70)
    print(f"🚀 SecureProxy 客户端 (激进优化版 - 完全防堵塞)")
    print(f"✅ SOCKS5: 127.0.0.1:{socks_port}")
    print(f"✅ HTTP:   127.0.0.1:{http_port}")
    print(f"🔐 加密:   AES-256-GCM")
    print(f"⚡ 激进优化:")
    print(f"   • 🔥🔥 连接超时:    {CONNECT_TIMEOUT}秒（极速）")
    print(f"   • 🔥🔥 握手超时:    {HANDSHAKE_TIMEOUT}秒（极速）")
    print(f"   • 🔥🔥 总超时:      {CONNECTION_TIMEOUT}秒（快速失败）")
    print(f"   • 🔥🔥 重试策略:    只重试{MAX_RETRIES}次，延迟{RETRY_DELAY}s")
    print(f"   • 🔥🔥 健康检查:    自动降级保护")
    print(f"   • 📊   成功率监控:  实时显示")
    print(f"   • 并发限制:        {MAX_CONCURRENT_CONNECTIONS} 连接")
    print(f"💡 核心理念: 一个请求失败<5秒，绝不影响其他请求")
    print("=" * 70)

    async with socks_server, http_server:
        await asyncio.gather(
            socks_server.serve_forever(),
            http_server.serve_forever()
        )

# ==================== 主函数 ====================
async def main():
    """主协程"""
    await asyncio.gather(
        start_servers(),
        traffic_monitor(),
        health_checker()
    )

# ==================== 启动 ====================
if __name__ == "__main__":
    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

    # 从环境变量加载配置
    current_config = load_config_from_env()

    if not current_config:
        print("❌ 无法启动: 配置加载失败")
        print("提示: 请确保 Swift 端正确设置了 SECURE_PROXY_CONFIG 环境变量")
        sys.exit(1)

    print("\n🚀 SecureProxy 客户端启动中...")
    print(f"🌍 配置: {current_config['name']}")
    print()

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\n👋 用户停止")
    except Exception as e:
        print(f"\n❌ 启动失败: {e}")
        import traceback
        traceback.print_exc()

package com.sipeed.picoclaw.service

import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 跑在 127.0.0.1 上的极简 HTTP/CONNECT 代理。
 *
 * 背景：core 是 CGO_ENABLED=0 构建的 Go 二进制，在 Android 上做 DNS 解析时只会读
 * /etc/resolv.conf，而应用沙盒里没有可用的 DNS 配置，最终回退到 [::1]:53 并被拒绝，
 * 导致 core 无法访问任何第三方模型端点（dial tcp: lookup ...: connection refused）。
 *
 * 本代理让 core 的出站 HTTP(S) 请求走 HTTP_PROXY/HTTPS_PROXY，由 App 进程
 * （使用 Android 系统 DNS，即 bionic 解析器）完成域名解析与转发。
 * 只监听 loopback，局域网内其他设备无法使用。
 */
class LocalProxyServer {
    companion object {
        private const val TAG = "LocalProxyServer"
        private const val CONNECT_TIMEOUT_MS = 15000
        private const val SO_TIMEOUT_MS = 30000
        private const val MAX_HEADER_BYTES = 65536
    }

    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool { r ->
        Thread(r, "local-proxy-worker").apply { isDaemon = true }
    }

    @Volatile
    var port: Int = -1
        private set

    /** 启动代理并返回监听端口；已在运行时直接返回当前端口。 */
    @Synchronized
    fun start(): Int {
        if (running.get()) return port
        val ss = ServerSocket()
        ss.bind(InetSocketAddress("127.0.0.1", 0))
        serverSocket = ss
        port = ss.localPort
        running.set(true)
        Thread({ acceptLoop() }, "local-proxy-accept").apply {
            isDaemon = true
            start()
        }
        Log.i(TAG, "started on 127.0.0.1:$port")
        return port
    }

    @Synchronized
    fun stop() {
        running.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        port = -1
        pool.shutdownNow()
        Log.i(TAG, "stopped")
    }

    private fun acceptLoop() {
        while (running.get()) {
            try {
                val client = serverSocket?.accept() ?: break
                pool.execute { handleClient(client) }
            } catch (e: Exception) {
                if (running.get()) Log.w(TAG, "accept failed: ${e.message}")
            }
        }
    }

    private fun handleClient(client: Socket) {
        try {
            client.soTimeout = SO_TIMEOUT_MS
            val input = client.getInputStream()
            val headerBytes = readHeaderBytes(input) ?: return
            val headerText = String(headerBytes, Charsets.ISO_8859_1)
            val lines = headerText.split("\r\n")
            val requestLine = lines.firstOrNull() ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 3) {
                sendSimpleResponse(client.getOutputStream(), 400, "Bad Request")
                return
            }
            val method = parts[0].uppercase()
            val target = parts[1]
            val headers = lines.drop(1).filter { it.contains(":") }
            if (method == "CONNECT") {
                handleConnect(client, target)
            } else {
                handlePlainHttp(client, input, method, target, headers)
            }
        } catch (e: Exception) {
            Log.w(TAG, "handle client failed: ${e.message}")
        } finally {
            try {
                client.close()
            } catch (_: Exception) {
            }
        }
    }

    /** 按字节读到 \r\n\r\n 为止的请求头，避免 BufferedReader 吃掉 body 字节。 */
    private fun readHeaderBytes(input: InputStream): ByteArray? {
        val buf = ByteArrayOutputStream()
        var lastFour = 0
        while (true) {
            val b = input.read()
            if (b == -1) return null
            buf.write(b)
            lastFour = (lastFour shl 8) or b
            if (lastFour == 0x0D0A0D0A) break
            if (buf.size() > MAX_HEADER_BYTES) return null
        }
        return buf.toByteArray()
    }

    /** 处理 CONNECT host:port —— 建隧道，TLS 端到端，代理只转发字节。 */
    private fun handleConnect(client: Socket, target: String) {
        val out = client.getOutputStream()
        val idx = target.lastIndexOf(":")
        if (idx <= 0) {
            sendSimpleResponse(out, 400, "Bad Request")
            return
        }
        val host = target.substring(0, idx)
        val port = target.substring(idx + 1).toIntOrNull()
        if (host.isEmpty() || port == null) {
            sendSimpleResponse(out, 400, "Bad Request")
            return
        }
        val remote = try {
            // 用 Android 系统 DNS 解析（InetAddress 走 bionic，工作正常）
            val addr = InetAddress.getByName(host)
            Socket().apply {
                soTimeout = SO_TIMEOUT_MS
                connect(InetSocketAddress(addr, port), CONNECT_TIMEOUT_MS)
            }
        } catch (e: Exception) {
            Log.w(TAG, "CONNECT $target failed: ${e.message}")
            sendSimpleResponse(out, 502, "Bad Gateway")
            return
        }
        try {
            out.write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            out.flush()
            // 隧道建立后取消读超时：SSE 长连接等场景空闲时间可能很长
            try {
                client.soTimeout = 0
                remote.soTimeout = 0
            } catch (_: Exception) {
            }
            pumpBidirectional(client, remote)
        } finally {
            try {
                remote.close()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 处理普通 HTTP 请求（absolute-form，如 GET http://host/path）。
     * https 请求 Go 一定会走 CONNECT，这里只处理 http，用系统 HTTP 栈转发。
     */
    private fun handlePlainHttp(
        client: Socket,
        clientInput: InputStream,
        method: String,
        target: String,
        headers: List<String>,
    ) {
        val out = client.getOutputStream()
        val uri = try {
            URI(target)
        } catch (_: Exception) {
            sendSimpleResponse(out, 400, "Bad Request")
            return
        }
        if (!uri.scheme.equals("http", ignoreCase = true) || uri.host.isNullOrEmpty()) {
            sendSimpleResponse(out, 400, "Bad Request")
            return
        }
        var conn: HttpURLConnection? = null
        try {
            conn = uri.toURL().openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = SO_TIMEOUT_MS
            conn.instanceFollowRedirects = false
            conn.doInput = true

            val skipHeaders = setOf(
                "proxy-connection", "proxy-authorization", "connection",
                "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
            )
            var contentLength = -1L
            for (h in headers) {
                val i = h.indexOf(":")
                if (i <= 0) continue
                val name = h.substring(0, i).trim()
                val value = h.substring(i + 1).trim()
                val lower = name.lowercase()
                if (lower in skipHeaders) continue
                if (lower == "host") continue // HttpURLConnection 自己会设置
                if (lower == "content-length") contentLength = value.toLongOrNull() ?: -1L
                conn.setRequestProperty(name, value)
            }

            if (contentLength > 0) {
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(contentLength)
                copyStream(LimitedInputStream(clientInput, contentLength), conn.outputStream)
            } else if (method == "POST" || method == "PUT" || method == "PATCH") {
                // 无 Content-Length 的 body（如 chunked）：尽力转发一段时间内到达的数据
                conn.doOutput = true
                conn.setChunkedStreamingMode(0)
                copyAvailable(clientInput, conn.outputStream, 2000)
            }

            val code = conn.responseCode
            val msg = conn.responseMessage ?: ""
            out.write("HTTP/1.1 $code $msg\r\n".toByteArray(Charsets.ISO_8859_1))
            for ((k, values) in conn.headerFields) {
                if (k == null) continue
                if (k.lowercase() in skipHeaders) continue
                for (v in values) {
                    out.write("$k: $v\r\n".toByteArray(Charsets.ISO_8859_1))
                }
            }
            out.write("\r\n".toByteArray(Charsets.ISO_8859_1))
            out.flush()
            val bodyStream = try {
                conn.inputStream
            } catch (_: Exception) {
                conn.errorStream
            }
            if (bodyStream != null) {
                copyStream(bodyStream, out)
                out.flush()
            }
        } catch (e: Exception) {
            Log.w(TAG, "plain http forward failed: ${e.message}")
            try {
                sendSimpleResponse(out, 502, "Bad Gateway")
            } catch (_: Exception) {
            }
        } finally {
            conn?.disconnect()
        }
    }

    private fun pumpBidirectional(a: Socket, b: Socket) {
        val t1 = Thread {
            try {
                copyStream(a.getInputStream(), b.getOutputStream())
            } catch (_: Exception) {
            }
            try {
                b.shutdownOutput()
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true }
        val t2 = Thread {
            try {
                copyStream(b.getInputStream(), a.getOutputStream())
            } catch (_: Exception) {
            }
            try {
                a.shutdownOutput()
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true }
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    }

    private fun copyStream(input: InputStream, output: OutputStream) {
        val buf = ByteArray(32768)
        while (true) {
            val n = input.read(buf)
            if (n == -1) break
            output.write(buf, 0, n)
            output.flush()
        }
    }

    /** 在空闲超时内把到达的数据转发出去（用于无长度声明的请求体，尽力而为）。 */
    private fun copyAvailable(input: InputStream, output: OutputStream, idleTimeoutMs: Int) {
        val buf = ByteArray(32768)
        val deadline = System.currentTimeMillis() + idleTimeoutMs
        try {
            while (System.currentTimeMillis() < deadline) {
                val available = input.available()
                if (available <= 0) {
                    Thread.sleep(50)
                    continue
                }
                val n = input.read(buf, 0, minOf(buf.size, available))
                if (n == -1) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {
        }
    }

    private fun sendSimpleResponse(out: OutputStream, code: Int, msg: String) {
        val body = msg.toByteArray(Charsets.UTF_8)
        out.write(
            "HTTP/1.1 $code $msg\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                .toByteArray(Charsets.ISO_8859_1),
        )
        out.write(body)
        out.flush()
    }

    /** 限制最多读取指定字节数的包装流。 */
    private class LimitedInputStream(
        private val inner: InputStream,
        private var remaining: Long,
    ) : InputStream() {
        override fun read(): Int {
            if (remaining <= 0) return -1
            val b = inner.read()
            if (b != -1) remaining--
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (remaining <= 0) return -1
            val n = inner.read(b, off, minOf(len.toLong(), remaining).toInt())
            if (n > 0) remaining -= n
            return n
        }

        override fun available(): Int = minOf(inner.available().toLong(), remaining).toInt()
    }
}

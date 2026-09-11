# 在线视频播放与下载站（前后端分离）

基于 Go 标准库实现的在线视频网站，**后端 API** 与 **前端静态页面** 完全分离。

## 目录结构

```
ollama/
├── main.go          # 后端：Go HTTP 服务（API + 静态托管）
├── go.mod
├── static/          # 前端：纯静态页面（HTML/CSS/JS）
│   ├── index.html
│   ├── style.css
│   └── app.js
├── videos/          # 视频存放目录（放进去自动识别）
└── README.md
```

## 运行

```bash
cd ollama
go run .            # 或 go build -o video-site . && ./video-site
```

打开浏览器访问 http://localhost:8106

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PORT` | 监听端口 | `8080` |
| `VIDEO_DIR` | 视频存储目录 | `/Users/even/mine/some` |
| `STATIC_DIR` | 前端目录 | `./static` |

## 后端 API

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/videos` | 获取视频列表（名称、大小、播放/下载地址） |
| `GET` | `/api/stream/{name}` | 流式播放，支持 HTTP Range（拖动进度） |
| `GET` | `/api/download/{name}` | 以附件形式下载 |
| `POST` | `/api/upload` | 上传视频（multipart，多文件） |
| `DELETE` | `/api/videos/{name}` | 删除视频 |

已内置路径穿越防护（仅允许访问 `VIDEO_DIR` 内文件）与 CORS 头，便于前后端独立部署。

## 使用

1. 点击右上角「上传视频」添加文件（或把文件直接放进 `videos/` 目录）。
2. 点击卡片「播放」在线观看，支持进度拖动（基于 Range 请求）。
3. 点击「下载」保存视频。
4. 点击「删除」移除视频。

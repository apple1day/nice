const grid = document.getElementById('grid');
const empty = document.getElementById('empty');
const search = document.getElementById('search');
const player = document.getElementById('player');
const playerTitle = document.getElementById('playerTitle');
const videoEl = document.getElementById('videoEl');
const uploadInput = document.getElementById('uploadInput');
const toast = document.getElementById('toast');

// 视图与 tab
const tabLibrary = document.getElementById('tabLibrary');
const tabWatch = document.getElementById('tabWatch');
const viewLibrary = document.getElementById('viewLibrary');
const viewWatch = document.getElementById('viewWatch');

// 观看视图元素
const watchSide = document.getElementById('watchSide');
const watchList = document.getElementById('watchList');
const watchTitle = document.getElementById('watchTitle');
const watchVideo = document.getElementById('watchVideo');
const watchDelete = document.getElementById('watchDelete');
const nextBtn = document.getElementById('nextBtn');
const collapseSide = document.getElementById('collapseSide');
const downloadAllBtn = document.getElementById('downloadAllBtn');

let videos = [];
let currentWatchIndex = -1;
let packing = false;

function fmtTime(iso) {
  if (!iso) return '未知时间';
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : d.toLocaleString();
}

function fmtSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let i = -1, n = bytes;
  do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
  return n.toFixed(1) + ' ' + units[i];
}

function showToast(msg) {
  toast.textContent = msg;
  toast.classList.remove('hidden');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => toast.classList.add('hidden'), 2500);
}

async function loadVideos() {
  try {
    const res = await fetch('/api/videos');
    const data = await res.json();
    videos = data.videos || [];
    render();
    renderWatchList();
  } catch (e) {
    showToast('加载视频失败: ' + e.message);
  }
}

// ---------- 视频库网格 ----------
function render() {
  const kw = search.value.trim().toLowerCase();
  const list = videos.filter(v => v.name.toLowerCase().includes(kw));
  grid.innerHTML = '';
  empty.classList.toggle('hidden', list.length > 0);

  for (const v of list) {
    const card = document.createElement('div');
    card.className = 'card' + (v.downloaded ? ' downloaded' : '');
    const badge = v.downloaded
      ? `<span class="badge-downloaded" title="下载时间：${fmtTime(v.downloadedAt)}">✓ 已下载</span>`
      : '';
    card.innerHTML = `
      <div class="thumb">▶${v.downloaded ? '<span class="thumb-badge">已下载</span>' : ''}</div>
      <div class="card-body">
        <div class="card-title" title="${v.name}">${v.name}</div>
        <div class="card-meta">${fmtSize(v.size)}${badge}</div>
        <div class="card-actions">
          <button class="btn btn-primary" data-act="play">播放</button>
          <a class="btn" data-act="download" href="${v.downloadUrl}" download>下载</a>
          <button class="btn btn-danger" data-act="delete">删除</button>
        </div>
      </div>`;

    card.querySelector('[data-act="play"]').addEventListener('click', (e) => {
      e.stopPropagation();
      openPlayer(v);
    });
    card.querySelector('[data-act="download"]').addEventListener('click', (e) => {
      e.stopPropagation();
      // 后端会记录下载，稍后刷新以更新「已下载」标记
      setTimeout(loadVideos, 1200);
    });
    card.querySelector('[data-act="delete"]').addEventListener('click', async (e) => {
      e.stopPropagation();
      if (!confirm('确定删除「' + v.name + '」？')) return;
      try {
        const res = await fetch('/api/videos/' + encodeURIComponent(v.name), { method: 'DELETE' });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) {
          showToast('删除失败: ' + (data.error || res.status));
          return;
        }
        showToast('已删除: ' + v.name);
        loadVideos();
      } catch (err) {
        showToast('删除请求出错: ' + err.message);
      }
    });
    card.addEventListener('click', () => openPlayer(v));

    grid.appendChild(card);
  }
}

function openPlayer(v) {
  playerTitle.textContent = v.name;
  videoEl.src = v.url;
  videoEl.play().catch(() => {});
  player.classList.remove('hidden');
  player.scrollIntoView({ behavior: 'smooth' });
}

document.getElementById('closePlayer').addEventListener('click', () => {
  videoEl.pause();
  videoEl.removeAttribute('src');
  videoEl.load();
  player.classList.add('hidden');
});

search.addEventListener('input', render);

// ---------- 观看视图 ----------
function renderWatchList() {
  watchList.innerHTML = '';
  if (videos.length === 0) {
    watchList.innerHTML = '<li class="watch-empty">暂无视频，去「视频库」上传吧</li>';
    return;
  }
  videos.forEach((v, i) => {
    const li = document.createElement('li');
    li.className = 'watch-item' + (i === currentWatchIndex ? ' active' : '');
    li.innerHTML = `
      <span class="wi-name" title="${v.name}">${v.name}</span>
      ${v.downloaded ? '<span class="wi-flag" title="已下载">✓</span>' : ''}
      <button class="wi-del" title="删除" data-i="${i}">✕</button>`;
    li.addEventListener('click', (e) => {
      if (e.target.closest('.wi-del')) return;
      openWatch(i);
    });
    li.querySelector('.wi-del').addEventListener('click', (e) => {
      e.stopPropagation();
      deleteVideoAt(i);
    });
    watchList.appendChild(li);
  });
}

function openWatch(index) {
  if (index < 0 || index >= videos.length) return;
  currentWatchIndex = index;
  const v = videos[index];
  watchTitle.textContent = v.name;
  watchVideo.src = v.url;
  watchVideo.play().catch(() => {});
  renderWatchList();
  const active = watchList.querySelector('.watch-item.active');
  if (active) active.scrollIntoView({ block: 'nearest' });
}

function playNext() {
  if (videos.length === 0) { currentWatchIndex = -1; return; }
  let next = currentWatchIndex + 1;
  if (next >= videos.length) next = 0; // 播到末尾后回到第一个，连续播放
  openWatch(next);
}

async function deleteVideoAt(index) {
  const v = videos[index];
  if (!v) return;
  if (!confirm('确定删除「' + v.name + '」？')) return;
  try {
    const res = await fetch('/api/videos/' + encodeURIComponent(v.name), { method: 'DELETE' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      showToast('删除失败: ' + (data.error || res.status));
      return;
    }
    showToast('已删除: ' + v.name);
    const target = index; // 删除后同一位置会补上原后续视频
    await loadVideos();
    if (videos.length === 0) {
      currentWatchIndex = -1;
      watchTitle.textContent = '';
      watchVideo.removeAttribute('src');
      watchVideo.load();
    } else {
      openWatch(Math.min(target, videos.length - 1));
    }
  } catch (err) {
    showToast('删除请求出错: ' + err.message);
  }
}

// 收起 / 展开播放列表
collapseSide.addEventListener('click', () => {
  watchSide.classList.toggle('collapsed');
  collapseSide.textContent = watchSide.classList.contains('collapsed') ? '‹ 展开' : '收起 ›';
});

nextBtn.addEventListener('click', playNext);
watchDelete.addEventListener('click', () => {
  if (currentWatchIndex >= 0) deleteVideoAt(currentWatchIndex);
});

// 视频播完自动播放下一个
watchVideo.addEventListener('ended', playNext);

// 上滑播放下一个（移动端触摸）
let touchStartY = 0;
watchVideo.addEventListener('touchstart', (e) => { touchStartY = e.touches[0].clientY; }, { passive: true });
watchVideo.addEventListener('touchend', (e) => {
  const dy = touchStartY - e.changedTouches[0].clientY;
  if (dy > 50) playNext(); // 上滑
}, { passive: true });

// 滚轮向下播放下一个（桌面端，带防抖）
let wheelLock = false;
watchVideo.addEventListener('wheel', (e) => {
  if (e.deltaY > 30 && !wheelLock) {
    wheelLock = true;
    playNext();
    setTimeout(() => { wheelLock = false; }, 800);
  }
}, { passive: true });

// 方向键 ↓ / PageDown 播放下一个（桌面端）
document.addEventListener('keydown', (e) => {
  if (viewWatch.classList.contains('hidden')) return;
  if (e.key === 'ArrowDown' || e.key === 'PageDown') {
    e.preventDefault();
    playNext();
  }
});

// ---------- tab 切换 ----------
function switchTab(name) {
  const isWatch = name === 'watch';
  tabWatch.classList.toggle('active', isWatch);
  tabLibrary.classList.toggle('active', !isWatch);
  viewWatch.classList.toggle('hidden', !isWatch);
  viewLibrary.classList.toggle('hidden', isWatch);
  if (isWatch) {
    if (currentWatchIndex < 0 && videos.length > 0) openWatch(0);
    else watchVideo.play().catch(() => {});
  } else {
    watchVideo.pause();
  }
}
tabLibrary.addEventListener('click', () => switchTab('library'));
tabWatch.addEventListener('click', () => switchTab('watch'));

// ---------- 一键下载全部 ----------

// triggerDownload 通过隐藏 iframe 触发下载，避免页面被导航走、也避免被浏览器拦截
function triggerDownload(url, filename) {
  let frame = document.getElementById('dlFrame');
  if (!frame) {
    frame = document.createElement('iframe');
    frame.id = 'dlFrame';
    frame.name = 'dlFrame';
    frame.style.display = 'none';
    document.body.appendChild(frame);
  }
  const a = document.createElement('a');
  a.href = url;
  a.target = 'dlFrame';
  if (filename) a.download = filename;
  a.rel = 'noopener';
  a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  setTimeout(() => a.remove(), 1000);
}

function resetDownloadAllBtn() {
  packing = false;
  downloadAllBtn.disabled = false;
  downloadAllBtn.textContent = '一键下载全部';
}

downloadAllBtn.addEventListener('click', () => {
  if (packing) return;
  if (!videos.length) { showToast('视频库为空，没有可下载的视频'); return; }

  const total = videos.reduce((s, v) => s + (v.size || 0), 0);
  if (total > 2 * 1024 * 1024 * 1024 &&
      !confirm('共 ' + videos.length + ' 个视频，合计约 ' + fmtSize(total) + '。\n打包会持续较久，中途请勿关闭页面，确定继续？')) {
    return;
  }

  packing = true;
  downloadAllBtn.disabled = true;
  downloadAllBtn.textContent = '打包中 0/' + videos.length;
  showToast('正在打包 ' + videos.length + ' 个视频（约 ' + fmtSize(total) + '），请稍候…');

  triggerDownload('/api/download-all?t=' + Date.now(), 'videos.zip');

  // 打包期间持续刷新，逐个点亮「已下载」标记；全部标记完成即停止
  let tries = 0;
  const timer = setInterval(async () => {
    tries++;
    await loadVideos();
    const done = videos.filter(v => v.downloaded).length;
    downloadAllBtn.textContent = '打包中 ' + done + '/' + videos.length;
    if ((videos.length > 0 && done === videos.length) || tries >= 60) {
      clearInterval(timer);
      resetDownloadAllBtn();
      showToast(done === videos.length ? '打包完成，已全部标记为已下载' : '打包仍在后台进行，已标记 ' + done + '/' + videos.length);
    }
  }, 5000);
});

// ---------- 上传 ----------
uploadInput.addEventListener('change', async () => {
  const files = uploadInput.files;
  if (!files.length) return;
  for (const file of files) {
    const fd = new FormData();
    fd.append('file', file);
    try {
      const res = await fetch('/api/upload', { method: 'POST', body: fd });
      const data = await res.json();
      if (data.error) { showToast(data.error); }
      else { showToast('上传成功: ' + file.name); }
    } catch (e) {
      showToast('上传失败: ' + file.name);
    }
  }
  uploadInput.value = '';
  loadVideos();
});

loadVideos();

;; -*- Mode: Irken -*-

;; the browsing page: a grid of thumbnails and a full-screen viewer with
;;  a slideshow.  the server fills in only the title and the directory's
;;  contents (a JSON object, PHOTOS); the script does the rest.
;;
;; (the CSS and the script are kept free of double quotes and
;;  backslashes, so they can sit in Irken strings as they are.)

(define photos/css "
:root { color-scheme: dark; }
[hidden] { display: none !important; }
body { margin: 0; background: #111; color: #ddd; font: 15px system-ui, sans-serif; }
a { color: #8cf; text-decoration: none; }
header { padding: 10px 14px; font-size: 18px; position: sticky; top: 0; background: #111e; z-index: 1; }
header .sep { color: #666; margin: 0 6px; }
header { display: flex; align-items: baseline; flex-wrap: wrap; }
header .count { color: #888; font-size: 14px; margin-left: 12px; }
header .sideways { margin-left: auto; font-size: 15px; display: flex; gap: 14px; }
header .sideways a, header .sideways span { white-space: nowrap; }
header .sideways span { color: #555; }
#dirs { display: flex; flex-wrap: wrap; gap: 6px; padding: 4px 14px 10px; }
#dirs a { background: #222; border: 1px solid #333; border-radius: 6px; padding: 6px 10px; }
#dirs a:hover { background: #2c2c2c; }
#grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(var(--cell, 170px), 1fr));
        gap: 6px; padding: 0 14px 20px; }
#grid a { aspect-ratio: 1; background: #1a1a1a; display: flex; align-items: center;
          justify-content: center; overflow: hidden; border-radius: 4px; outline-offset: 2px; }
#grid a.current { outline: 2px solid #8cf; }
#grid img { max-width: 100%; max-height: 100%; }
#grid .name { font-size: 12px; color: #888; padding: 4px; word-break: break-all; text-align: center; }
#viewer { position: fixed; inset: 0; background: #000; z-index: 2; display: flex;
          align-items: center; justify-content: center; }
#full { max-width: 100vw; max-height: 100vh; object-fit: contain; }
#bar { position: fixed; left: 0; right: 0; bottom: 0; display: flex; gap: 6px; align-items: center;
       padding: 8px 12px; background: linear-gradient(transparent, #000c); transition: opacity 0.4s; }
#bar.idle { opacity: 0; }
#bar button, #bar select, #bar a { background: #222c; color: #ddd; border: 1px solid #444; border-radius: 5px;
       font-size: 16px; padding: 4px 10px; cursor: pointer; }
#caption { flex: 1; text-align: center; color: #ccc; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
#info a { color: #8cf; }
#info { position: fixed; top: 10px; right: 10px; background: #000b; border: 1px solid #333;
        border-radius: 6px; padding: 8px 12px; font-size: 13px; line-height: 1.5; white-space: pre; }
")

(define photos/script "
(function () {
  const P = PHOTOS;
  const $ = (id) => document.getElementById(id);
  const join = (a, b) => (a === '' ? b : a + '/' + b);
  const enc = (path) => path.split('/').map(encodeURIComponent).join('/');
  const url = (kind, name) => '/' + kind + '/' + enc(join(P.dir, name));
  const el = (tag, props) => Object.assign(document.createElement(tag), props || {});

  // the path, as links.
  const header = $('crumbs');
  header.append(el('a', {href: '/b/', textContent: 'photos'}));
  let acc = '';
  for (const part of (P.dir === '' ? [] : P.dir.split('/'))) {
    acc = join(acc, part);
    header.append(el('span', {className: 'sep', textContent: '/'}));
    header.append(el('a', {href: '/b/' + enc(acc) + '/', textContent: part}));
  }
  if (P.images.length > 0)
    header.append(el('span', {className: 'count', textContent: P.images.length + ' images'}));

  // sideways: the directories before and after this one in its parent.
  const last = (path) => path.split('/').pop();
  const dirURL = (path) => '/b/' + enc(path) + '/';
  if (P.prev || P.next) {
    const side = el('span', {className: 'sideways'});
    side.append(P.prev ? el('a', {href: dirURL(P.prev), title: 'previous directory ([)', innerHTML: '&larr; '})
                       : el('span', {innerHTML: '&larr;'}));
    if (P.prev) side.lastChild.append(last(P.prev));
    side.append(P.next ? el('a', {href: dirURL(P.next), title: 'next directory (])', textContent: last(P.next) + ' '})
                       : el('span', {innerHTML: '&rarr;'}));
    if (P.next) side.lastChild.insertAdjacentHTML('beforeend', '&rarr;');
    header.append(side);
  }

  for (const d of P.dirs)
    $('dirs').append(el('a', {href: '/b/' + enc(join(P.dir, d)) + '/', textContent: d}));

  // the thumbnails.
  const cells = P.images.map((name, i) => {
    const a = el('a', {href: '#' + encodeURIComponent(name), title: name});
    const img = el('img', {loading: 'lazy', decoding: 'async', alt: name, src: url('t', name)});
    // e.g. a HEIC thumbnail outside Safari: show the name instead.
    img.onerror = () => img.replaceWith(el('span', {className: 'name', textContent: name}));
    a.append(img);
    a.onclick = (e) => { e.preventDefault(); show(i); };
    $('grid').append(a);
    return a;
  });

  // the viewer.
  const viewer = $('viewer'), full = $('full'), bar = $('bar'), info = $('info');
  let index = -1, playing = false, timer = null;
  const delay = () => Number($('delay').value) * 1000;

  function show(i) {
    const n = P.images.length;
    if (n === 0) return;
    if (index >= 0) cells[index].classList.remove('current');
    index = ((i % n) + n) % n;
    cells[index].classList.add('current');
    const name = P.images[index];
    clearTimeout(timer);
    // a full image the browser can't show (a HEIC outside Safari): fall
    //  back to the thumbnail.
    full.onerror = () => { full.onerror = null; full.src = url('t', name); };
    full.src = url('i', name);
    $('caption').textContent = name + '   ' + (index + 1) + ' / ' + n;
    viewer.hidden = false;
    history.replaceState(null, '', '#' + encodeURIComponent(name));
    updateMeta(name);
    // fetch the next one now, so it's there when it's wanted.
    if (n > 1) el('img', {src: url('i', P.images[(index + 1) % n])});
    wake();
  }

  // the slideshow moves on once the image is loaded and has been up a while.
  full.onload = () => {
    if (playing) { clearTimeout(timer); timer = setTimeout(() => show(index + 1), delay()); }
  };

  function play(on) {
    playing = on;
    $('play').innerHTML = on ? '&#10074;&#10074;' : '&#9654;';
    clearTimeout(timer);
    if (on) timer = setTimeout(() => show(index + 1), delay());
  }

  function close() {
    play(false);
    viewer.hidden = true;
    if (document.fullscreenElement) document.exitFullscreen();
    history.replaceState(null, '', location.pathname);
    if (index >= 0) cells[index].scrollIntoView({block: 'nearest'});
  }

  // what /x/ says about each image (date, camera, location...), fetched
  //  once.
  const metas = new Map();
  function meta(name) {
    if (!metas.has(name))
      metas.set(name, fetch(url('x', name)).then((r) => r.json()).catch(() => null));
    return metas.get(name);
  }
  const mapURL = (gps) => 'https://www.google.com/maps/search/?api=1&query=' + gps;

  // the globe button, if the image has a location; and the info panel.
  function updateMeta(name) {
    const map = $('map');
    map.hidden = true;
    meta(name).then((x) => {
      if (P.images[index] !== name || !x) return;
      if (x.gps) { map.href = mapURL(x.gps); map.hidden = false; }
      if (!info.hidden) showInfo(name, x);
    });
  }

  function loadInfo() {
    const name = P.images[index];
    info.textContent = name;
    meta(name).then((x) => { if (P.images[index] === name && x) showInfo(name, x); });
  }

  function showInfo(name, x) {
    {
      const lines = [name];
      if (x.date) lines.push(x.date);
      // (models often repeat the make: Canon Canon PowerShot S230)
      const camera = x.model.startsWith(x.make.split(' ')[0]) ? x.model : [x.make, x.model].filter(Boolean).join(' ');
      if (camera) lines.push(camera);
      if (x.width) lines.push(x.width + ' x ' + x.height);
      if (x.stale) lines.push('(orientation tag was stale: ignored)');
      lines.push((x.size / 1e6).toFixed(1) + ' MB');
      info.textContent = lines.join(String.fromCharCode(10));
      if (x.gps) {
        info.append(String.fromCharCode(10));
        info.append(el('a', {href: mapURL(x.gps), target: '_blank', rel: 'noopener',
                             textContent: x.gps.replace(',', ', ')}));
      }
    }
  }

  function toggleInfo() { info.hidden = !info.hidden; if (!info.hidden) loadInfo(); }

  function fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen();
    else viewer.requestFullscreen();
  }

  // the controls fade out when the mouse is still.
  let idle = null;
  function wake() {
    bar.classList.remove('idle');
    clearTimeout(idle);
    idle = setTimeout(() => bar.classList.add('idle'), 2500);
  }
  viewer.onmousemove = wake;

  $('prev').onclick = (e) => { e.stopPropagation(); show(index - 1); };
  $('next').onclick = (e) => { e.stopPropagation(); show(index + 1); };
  $('play').onclick = (e) => { e.stopPropagation(); play(!playing); };
  $('infob').onclick = (e) => { e.stopPropagation(); toggleInfo(); };
  $('fs').onclick = (e) => { e.stopPropagation(); fullscreen(); };
  $('close').onclick = (e) => { e.stopPropagation(); close(); };
  $('delay').onclick = (e) => e.stopPropagation();
  // clicking the image: the left third goes back, the rest forward.
  full.onclick = (e) => (e.clientX < window.innerWidth / 3 ? show(index - 1) : show(index + 1));

  document.onkeydown = (e) => {
    if (viewer.hidden) {
      if (e.key === 'Enter' && P.images.length) show(0);
      else if (e.key === '[' && P.prev) location.href = dirURL(P.prev);
      else if (e.key === ']' && P.next) location.href = dirURL(P.next);
      return;
    }
    switch (e.key) {
      case 'ArrowRight': case 'PageDown': show(index + 1); break;
      case 'ArrowLeft': case 'PageUp': show(index - 1); break;
      case 'Home': show(0); break;
      case 'End': show(P.images.length - 1); break;
      case ' ': play(!playing); break;
      case 'Escape': close(); break;
      case 'i': toggleInfo(); break;
      case 'f': fullscreen(); break;
      case 'm': if (!$('map').hidden) window.open($('map').href, '_blank', 'noopener'); break;
      default: return;
    }
    e.preventDefault();
  };

  // swiping, on a phone or tablet.
  let touchX = null;
  viewer.addEventListener('touchstart', (e) => { touchX = e.touches[0].clientX; }, {passive: true});
  viewer.addEventListener('touchend', (e) => {
    if (touchX === null) return;
    const dx = e.changedTouches[0].clientX - touchX;
    touchX = null;
    if (Math.abs(dx) > 50) show(dx < 0 ? index + 1 : index - 1);
  });

  // a link to a particular image (also followed when the hash changes,
  //  e.g. with the back button).
  function followHash() {
    if (location.hash.length > 1) {
      const i = P.images.indexOf(decodeURIComponent(location.hash.slice(1)));
      if (i >= 0 && (i !== index || viewer.hidden)) show(i);
    } else if (!viewer.hidden) {
      close();
    }
  }
  window.onhashchange = followHash;
  followHash();
})();
")

(define photos/body "
<header id='crumbs'></header>
<nav id='dirs'></nav>
<main id='grid'></main>
<div id='viewer' hidden>
  <img id='full' alt=''>
  <div id='info' hidden></div>
  <div id='bar'>
    <button id='prev' title='previous (left arrow)'>&larr;</button>
    <button id='play' title='slideshow (space)'>&#9654;</button>
    <select id='delay' title='seconds per image'>
      <option value='2'>2s</option><option value='5' selected>5s</option>
      <option value='10'>10s</option><option value='30'>30s</option>
    </select>
    <button id='next' title='next (right arrow)'>&rarr;</button>
    <span id='caption'></span>
    <a id='map' hidden target='_blank' rel='noopener' title='on Google Maps (m)'>&#x1F30D;</a>
    <button id='infob' title='info (i)'>i</button>
    <button id='fs' title='full screen (f)'>&#x26F6;</button>
    <button id='close' title='close (escape)'>&times;</button>
  </div>
</div>
")

;; <data> is the JSON for PHOTOS (made safe for <script> by json-string).
(define (photos/page title data)
  (string-concat
   (list "<!doctype html>\n<html><head><meta charset='utf-8'>"
         "<meta name='viewport' content='width=device-width, initial-scale=1'>"
         "<title>" (html-escape title) "</title>"
         "<link rel='icon' href='/favicon.svg'>"
         "<style>" photos/css "</style></head><body>"
         photos/body
         "<script>const PHOTOS = " data ";</script>"
         "<script>" photos/script "</script>"
         "</body></html>\n")))

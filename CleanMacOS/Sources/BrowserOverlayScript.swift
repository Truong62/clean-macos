enum BrowserOverlayScript {
    static let source = #"""
    (() => {
      if (window.__cmDemo) return;
      const NS = 'http://www.w3.org/2000/svg';
      const host = document.createElement('cm-demo-overlay');
      host.style.cssText = 'all:initial;position:fixed;left:0;top:0;width:100vw;height:100vh;pointer-events:none;z-index:2147483647;';
      const root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = `<style>
        *{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
        #stage{position:fixed;inset:0;overflow:hidden}
        svg.layer{position:fixed;left:0;top:0;width:100vw;height:100vh;overflow:visible}
        .draw{animation:draw .45s ease-out forwards}
        @keyframes draw{from{stroke-dashoffset:var(--len)}to{stroke-dashoffset:0}}
        .pop{animation:pop .3s ease-out both}
        @keyframes pop{from{opacity:0}to{opacity:1}}
        .bubble{position:fixed;color:#fff;font-weight:600;font-size:20px;line-height:1.25;padding:8px 14px;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.35);max-width:420px;width:max-content;text-align:center;white-space:pre-wrap}
        .badge{position:fixed;display:flex;align-items:center;gap:8px;transform-origin:top left}
        .badge b{flex:none;width:40px;height:40px;border-radius:20px;color:#fff;font-weight:800;font-size:22px;display:flex;align-items:center;justify-content:center;box-shadow:0 2px 6px rgba(0,0,0,.35)}
        .badge .bubble{position:static}
        .title{position:fixed;inset:0;background:rgba(0,0,0,.78);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;color:#fff;text-align:center;padding:60px}
        .title h1{margin:0;font-size:60px;font-weight:800}
        .title p{margin:0;font-size:28px;font-weight:500;opacity:.8}
        #caption{position:fixed;width:max-content;max-width:1100px;color:#fff;background:rgba(0,0,0,.78);font-size:28px;font-weight:600;padding:14px 26px;border-radius:16px;text-align:center;white-space:pre-wrap;transition:opacity .3s;opacity:0}
        #cursor{position:fixed;left:0;top:0;width:24px;height:34px;transition-property:transform;transition-timing-function:ease-in-out;filter:drop-shadow(0 1px 2px rgba(0,0,0,.45));display:none}
        .ripple{position:fixed;width:56px;height:56px;margin:-28px 0 0 -28px;border-radius:50%;border:3px solid #FF3B30;background:rgba(255,59,48,.35);animation:ripple .6s ease-out forwards}
        @keyframes ripple{from{transform:scale(.3);opacity:1}to{transform:scale(1.4);opacity:0}}
      </style><div id="stage"></div><div id="caption"></div><svg id="cursor" viewBox="0 0 24 34"><path d="M2 2 L2 26 L8 20 L12.5 30 L16.5 28.2 L12 18.5 L20 18.5 Z" fill="#000" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg>`;
      const stage = root.getElementById('stage');
      const captionBox = root.getElementById('caption');
      const cursor = root.getElementById('cursor');
      const state = { annotations: [], caption: null, captionTop: false, cursor: null, view: null };
      const nodes = new Map();

      const mount = () => {
        const parent = document.documentElement || document.body;
        if (parent && !host.isConnected) parent.appendChild(host);
      };
      const view = () => state.view || { x: 0, y: 0, w: innerWidth, h: innerHeight, s: 1 };
      const svgEl = (tag, attrs) => {
        const el = document.createElementNS(NS, tag);
        for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
        return el;
      };
      const layer = () => svgEl('svg', { class: 'layer' });
      const stroke = (shape, color, width) => {
        shape.setAttribute('fill', 'none');
        shape.setAttribute('stroke', color);
        shape.setAttribute('stroke-width', width);
        shape.setAttribute('stroke-linecap', 'round');
        shape.setAttribute('stroke-linejoin', 'round');
        return shape;
      };
      const animateDraw = (shape) => {
        requestAnimationFrame(() => {
          const len = shape.getTotalLength ? shape.getTotalLength() : 1000;
          shape.style.setProperty('--len', len);
          shape.style.strokeDasharray = len;
          shape.style.strokeDashoffset = len;
          shape.classList.add('draw');
        });
      };
      const bubble = (text, color) => {
        const b = document.createElement('div');
        b.className = 'bubble pop';
        b.style.background = color;
        b.textContent = text;
        return b;
      };
      const placeBubble = (b, f) => {
        const k = 1 / view().s;
        const below = f.y + f.h + 70 * k < innerHeight;
        b.style.left = Math.min(Math.max(f.x + f.w / 2, 220 * k), innerWidth - 220 * k) + 'px';
        b.style.top = (below ? f.y + f.h + 12 * k : f.y - 12 * k) + 'px';
        b.style.transformOrigin = below ? 'top center' : 'bottom center';
        b.style.transform = `translate(-50%, ${below ? '0' : '-100%'}) scale(${k})`;
      };
      const inset = (r, dx, dy) => ({ x: r.x - dx, y: r.y - dy, w: r.w + 2 * dx, h: r.h + 2 * dy });
      const arrowPoints = (r) => {
        const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
        let dx = innerWidth / 2 - cx, dy = innerHeight / 2 - cy;
        const d = Math.hypot(dx, dy);
        if (d < 1) { dx = 0.6; dy = 0.8; } else { dx /= d; dy /= d; }
        const reach = Math.min(r.w, r.h) / 2 + 12;
        const end = { x: cx + dx * reach, y: cy + dy * reach };
        const clamp = (v, max) => Math.min(Math.max(v, 24), max - 24);
        const start = { x: clamp(end.x + dx * 170, innerWidth), y: clamp(end.y + dy * 170, innerHeight) };
        return { start, end };
      };

      const render = (a) => {
        const k = 1 / view().s;
        const r = { x: a.x, y: a.y, w: a.width, h: a.height };
        const group = document.createElement('div');
        group.className = 'pop';
        const color = a.color || '#FF3B30';
        if (a.kind === 'circle' || a.kind === 'box') {
          const svg = layer();
          let shape;
          if (a.kind === 'box') {
            const f = inset(r, 8, 8);
            shape = svgEl('rect', { x: f.x, y: f.y, width: f.w, height: f.h, rx: 10 });
          } else if (r.w > r.h * 4) {
            const f = inset(r, 10, 8);
            shape = svgEl('rect', { x: f.x, y: f.y, width: f.w, height: f.h, rx: f.h / 2 });
          } else {
            const f = inset(r, 16, 12);
            shape = svgEl('ellipse', { cx: f.x + f.w / 2, cy: f.y + f.h / 2, rx: f.w / 2, ry: f.h / 2 });
          }
          svg.appendChild(stroke(shape, color, (a.kind === 'box' ? 4 : 5) * k));
          group.appendChild(svg);
          animateDraw(shape);
          if (a.text) { const b = bubble(a.text, color); placeBubble(b, inset(r, 16, 12)); group.appendChild(b); }
        } else if (a.kind === 'arrow') {
          const { start, end } = arrowPoints(r);
          const svg = layer();
          const angle = Math.atan2(end.y - start.y, end.x - start.x), head = 22 * k;
          const line = svgEl('path', { d: `M${start.x} ${start.y} L${end.x} ${end.y}` });
          const tip = svgEl('path', { d: `M${end.x - head * Math.cos(angle - Math.PI / 7)} ${end.y - head * Math.sin(angle - Math.PI / 7)} L${end.x} ${end.y} L${end.x - head * Math.cos(angle + Math.PI / 7)} ${end.y - head * Math.sin(angle + Math.PI / 7)}` });
          svg.appendChild(stroke(line, color, 6 * k));
          svg.appendChild(stroke(tip, color, 6 * k));
          group.appendChild(svg);
          animateDraw(line);
          if (a.text) {
            const b = bubble(a.text, color);
            const above = start.y < end.y;
            placeBubble(b, { x: start.x - 1, y: above ? start.y - 2 : start.y, w: 2, h: 2 });
            group.appendChild(b);
          }
        } else if (a.kind === 'text') {
          const b = bubble(a.text || '', color);
          placeBubble(b, r);
          group.appendChild(b);
        } else if (a.kind === 'step') {
          const badge = document.createElement('div');
          badge.className = 'badge';
          const n = document.createElement('b');
          n.style.background = color;
          n.textContent = a.number || 1;
          badge.appendChild(n);
          badge.style.left = (r.x - 20 * k) + 'px';
          badge.style.top = (r.y - 20 * k) + 'px';
          badge.style.transform = `scale(${k})`;
          group.appendChild(badge);
          if (a.text) { const b = bubble(a.text, color); placeBubble(b, inset(r, 4, 4)); group.appendChild(b); }
        } else if (a.kind === 'spotlight') {
          const f = inset(r, 14, 14);
          const svg = layer();
          const W = innerWidth, H = innerHeight, R = 14;
          const hole = `M${f.x + R} ${f.y} H${f.x + f.w - R} Q${f.x + f.w} ${f.y} ${f.x + f.w} ${f.y + R} V${f.y + f.h - R} Q${f.x + f.w} ${f.y + f.h} ${f.x + f.w - R} ${f.y + f.h} H${f.x + R} Q${f.x} ${f.y + f.h} ${f.x} ${f.y + f.h - R} V${f.y + R} Q${f.x} ${f.y} ${f.x + R} ${f.y} Z`;
          svg.appendChild(svgEl('path', { d: `M0 0 H${W} V${H} H0 Z ${hole}`, 'fill-rule': 'evenodd', fill: 'rgba(0,0,0,0.55)' }));
          svg.appendChild(stroke(svgEl('path', { d: hole }), color, 3 * k));
          group.appendChild(svg);
          if (a.text) { const b = bubble(a.text, color); placeBubble(b, f); group.appendChild(b); }
        } else if (a.kind === 'blur') {
          const box = document.createElement('div');
          box.style.cssText = `position:fixed;left:${r.x - 4}px;top:${r.y - 4}px;width:${r.w + 8}px;height:${r.h + 8}px;border-radius:8px;backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);background:rgba(128,128,128,.18)`;
          group.appendChild(box);
        } else if (a.kind === 'title') {
          const card = document.createElement('div');
          card.className = 'title';
          const lines = String(a.text || '').split('\n');
          const h1 = document.createElement('h1');
          h1.textContent = lines[0];
          card.appendChild(h1);
          for (const line of lines.slice(1)) { const p = document.createElement('p'); p.textContent = line; card.appendChild(p); }
          group.appendChild(card);
        }
        return group;
      };

      const layoutCaption = () => {
        if (!state.caption) { captionBox.style.opacity = '0'; return; }
        const v = view(), k = 1 / v.s;
        const band = { y: v.y + v.h - 150 * k, h: 150 * k };
        const blocked = state.annotations.some(a => a.kind !== 'title' && a.kind !== 'spotlight' && a.y + a.height + 50 > band.y && a.y - 50 < band.y + band.h)
          || (state.cursor && state.cursor.y > band.y - 40 * k && state.cursor.y < band.y + band.h);
        const top = state.captionTop || blocked;
        captionBox.textContent = state.caption;
        captionBox.style.left = (v.x + v.w / 2) + 'px';
        captionBox.style.top = (top ? v.y + 70 * k : v.y + v.h - 70 * k) + 'px';
        captionBox.style.transformOrigin = top ? 'top center' : 'bottom center';
        captionBox.style.transform = `translate(-50%, ${top ? '0' : '-100%'}) scale(${k})`;
        captionBox.style.opacity = '1';
      };

      const redraw = () => {
        stage.textContent = '';
        nodes.clear();
        for (const a of state.annotations) { const node = render(a); nodes.set(a.id, node); stage.appendChild(node); }
        layoutCaption();
      };

      window.__cmDemo = {
        annotate(a) {
          mount();
          this.remove(a.id, true);
          state.annotations.push(a);
          const node = render(a);
          nodes.set(a.id, node);
          stage.appendChild(node);
          layoutCaption();
        },
        remove(id, quiet) {
          state.annotations = state.annotations.filter(a => a.id !== id);
          const node = nodes.get(id);
          if (node) { node.remove(); nodes.delete(id); }
          if (!quiet) layoutCaption();
        },
        clear() { state.annotations = state.annotations.filter(a => a.kind === 'blur'); redraw(); },
        caption(text, top) { mount(); state.caption = text || null; state.captionTop = !!top; layoutCaption(); },
        cursor(x, y, ms) {
          mount();
          state.cursor = { x, y };
          cursor.style.display = 'block';
          cursor.style.transitionDuration = (ms || 0) + 'ms';
          cursor.style.transform = `translate(${x - 2}px, ${y - 2}px)`;
        },
        ripple(x, y) {
          mount();
          const r = document.createElement('div');
          r.className = 'ripple';
          r.style.left = x + 'px';
          r.style.top = y + 'px';
          stage.appendChild(r);
          setTimeout(() => r.remove(), 700);
        },
        view(v) { state.view = v; redraw(); },
        sync(s) {
          mount();
          Object.assign(state, s);
          redraw();
          if (state.cursor) this.cursor(state.cursor.x, state.cursor.y, 0);
        },
      };

      const norm = (s) => String(s || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return false;
        const st = getComputedStyle(el);
        return st.visibility !== 'hidden' && st.display !== 'none' && Number(st.opacity) > 0;
      };
      const interactive = 'a,button,input,textarea,select,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=switch],[role=option],[onclick],[tabindex]';
      const roleMatches = (el, role) => {
        if (!role) return true;
        role = role.toLowerCase();
        if (role === 'button') return el.matches('button,[role=button],input[type=submit],input[type=button]');
        if (role === 'link') return el.matches('a,[role=link]');
        if (role === 'textfield' || role === 'input') return el.matches('input,textarea,[contenteditable=""],[contenteditable=true]');
        return el.tagName.toLowerCase() === role || el.getAttribute('role') === role;
      };
      const boxOf = (el, useText) => {
        if (el.matches('input[type=checkbox],input[type=radio]')) {
          const r = el.getBoundingClientRect();
          const side = Math.min(18, r.width, r.height);
          return { left: r.left + r.width / 2 - side / 2, top: r.top + r.height / 2 - side / 2, width: side, height: side,
                   right: r.left + r.width / 2 + side / 2, bottom: r.top + r.height / 2 + side / 2 };
        }
        if (useText && !el.matches(interactive)) {
          const range = document.createRange();
          range.selectNodeContents(el);
          const r = range.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) return r;
        }
        return el.getBoundingClientRect();
      };
      window.__cmFind = (query, selector, role) => {
        const q = norm(query);
        const scored = [];
        const candidates = selector ? document.querySelectorAll(selector) : document.querySelectorAll('body *');
        for (const el of candidates) {
          if (el === host || !visible(el) || !roleMatches(el, role)) continue;
          let score = selector && !q ? 3 : 0;
          if (q) {
            for (const label of [el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('title'), el.getAttribute('alt'), typeof el.value === 'string' ? el.value : null, el.innerText]) {
              const t = norm(label);
              if (!t) continue;
              score = Math.max(score, t === q ? 3 : t.startsWith(q) ? 2 : t.includes(q) ? 1 : 0);
            }
          }
          if (!score) continue;
          const r = el.getBoundingClientRect();
          scored.push({ el, score, isInteractive: el.matches(interactive) ? 1 : 0, area: r.width * r.height });
        }
        if (q) scored.sort((a, b) => b.score - a.score || b.isInteractive - a.isInteractive || a.area - b.area);
        window.__cmFound = scored.map(x => x.el);
        window.__cmUseText = !selector;
        return scored.slice(0, 10).map((x, index) => {
          const r = boxOf(x.el, !selector);
          const text = norm(x.el.innerText || x.el.getAttribute('aria-label') || x.el.getAttribute('placeholder') || x.el.value).slice(0, 80);
          return { index, tag: x.el.tagName.toLowerCase(), text, x: r.left, y: r.top, width: r.width, height: r.height };
        });
      };
      window.__cmReveal = async (index, center) => {
        const el = (window.__cmFound || [])[index];
        if (!el) return null;
        let r = boxOf(el, window.__cmUseText);
        if (center || r.top < 0 || r.left < 0 || r.bottom > innerHeight || r.right > innerWidth) {
          el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
          await new Promise(done => setTimeout(done, 800));
          r = boxOf(el, window.__cmUseText);
        }
        return { x: r.left, y: r.top, width: r.width, height: r.height };
      };
      window.__cmBlurElement = (index, id) => {
        const el = (window.__cmFound || [])[index];
        if (!el) return null;
        el.style.setProperty('filter', 'blur(7px)', 'important');
        el.setAttribute('data-cm-blur', id);
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height };
      };
      window.__cmUnblur = (id) => {
        for (const el of document.querySelectorAll('[data-cm-blur]')) {
          if (el.getAttribute('data-cm-blur') !== id) continue;
          el.style.removeProperty('filter');
          el.removeAttribute('data-cm-blur');
        }
      };
      window.__cmFocus = (index) => {
        const el = (window.__cmFound || [])[index];
        if (!el) return false;
        el.focus();
        if (typeof el.setSelectionRange === 'function' && typeof el.value === 'string') {
          try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
        }
        return true;
      };
      document.addEventListener('DOMContentLoaded', mount);
      mount();
    })();
    """#
}

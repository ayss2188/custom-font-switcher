/* fontconv.js —— 在 WebUI 里把 WOFF / WOFF2 / ZIP 转成 TTF，再走正常导入流程
 *
 * 设计：
 *   · 只做"格式转换"，不碰设备、不改后端；转完得到的字节数组当作普通 TTF 交给现有上传逻辑
 *   · ZIP：用浏览器自带 DecompressionStream('deflate-raw') 解包（无需第三方库）
 *   · WOFF1：解析表目录 → 逐表用 DecompressionStream('deflate') 解压 → 重新拼成 SFNT
 *   · WOFF2：需要 Brotli + glyf 变换，交给随包的 woff2.js（wawoff2 的 wasm 解码器，离线可用）
 *   · 顺带检测"缺空格字符（U+0020）"，给出提示（自动补字需要改表，暂时只提示）
 */
(function () {
  "use strict";

  const TAG = {
    WOFF: 0x774F4646, WOFF2: 0x774F4632, ZIP: 0x504B0304,
  };

  function u32(b, o) { return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0; }
  function u16(b, o) { return (b[o] << 8) | b[o + 1]; }
  function tag4(b, o) { return String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]); }
  function le16(b, o) { return b[o] | (b[o + 1] << 8); }
  function le32(b, o) { return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0; }

  function putU32(a, o, v) { a[o] = (v >>> 24) & 255; a[o + 1] = (v >>> 16) & 255; a[o + 2] = (v >>> 8) & 255; a[o + 3] = v & 255; }
  function putU16(a, o, v) { a[o] = (v >>> 8) & 255; a[o + 1] = v & 255; }

  async function inflate(bytes, fmt) {
    const ds = new DecompressionStream(fmt || "deflate");
    const stream = new Blob([bytes]).stream().pipeThrough(ds);
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  function isFontName(n) { return /\.(ttf|otf|ttc|woff|woff2)$/i.test(n || ""); }
  function isTtfName(n) { return /\.(ttf|otf|ttc)$/i.test(n || ""); }
  function baseName(n) { return String(n || "").replace(/\.[^.]+$/, ""); }

  // ---------- WOFF1 → SFNT ----------
  async function woffToSfnt(buf) {
    const b = new Uint8Array(buf);
    if (u32(b, 0) !== TAG.WOFF) throw new Error("不是 WOFF1 文件");
    const flavor = u32(b, 4);
    const numTables = u16(b, 12);
    const totalSfntSize = u32(b, 16);
    if (!numTables) throw new Error("WOFF 表数量为 0");

    const tables = [];
    let p = 44;
    for (let i = 0; i < numTables; i++, p += 20) {
      const tag = b.slice(p, p + 4);
      const off = u32(b, p + 4);
      const compLen = u32(b, p + 8);
      const origLen = u32(b, p + 12);
      const checksum = u32(b, p + 16);
      let data;
      if (compLen < origLen) {
        data = await inflate(b.subarray(off, off + compLen), "deflate");
      } else {
        data = b.slice(off, off + origLen);
      }
      if (data.length !== origLen) throw new Error("WOFF 表解压长度不符：" + tag4(tag, 0));
      tables.push({ tag, data, checksum });
    }
    return buildSfnt(flavor, tables, totalSfntSize);
  }

  function buildSfnt(flavor, tables, totalSize) {
    tables.sort((a, b) => {
      const ta = tag4(a.tag, 0), tb = tag4(b.tag, 0);
      return ta < tb ? -1 : ta > tb ? 1 : 0;
    });
    const n = tables.length;
    let maxPow = 1, entrySel = 0;
    while (maxPow * 2 <= n) { maxPow *= 2; entrySel++; }
    const searchRange = maxPow * 16;
    const rangeShift = n * 16 - searchRange;

    let offset = 12 + n * 16;
    const head = new Uint8Array(offset);
    putU32(head, 0, flavor);
    putU16(head, 4, n);
    putU16(head, 6, searchRange);
    putU16(head, 8, entrySel);
    putU16(head, 10, rangeShift);

    let dir = 12;
    const chunks = [];
    let headOffset = -1;
    for (const t of tables) {
      head.set(t.tag, dir);
      putU32(head, dir + 4, t.checksum);
      putU32(head, dir + 8, offset);
      putU32(head, dir + 12, t.data.length);
      dir += 16;
      if (tag4(t.tag, 0) === "head") headOffset = offset;
      chunks.push(t.data);
      offset += t.data.length;
      const pad = (4 - (offset % 4)) % 4;
      if (pad) { chunks.push(new Uint8Array(pad)); offset += pad; }
    }

    const out = new Uint8Array(offset);
    out.set(head, 0);
    let o = head.length;
    for (const c of chunks) { out.set(c, o); o += c.length; }

    // head.checkSumAdjustment：先把 head 表里的该字段清零，再按整文件算
    if (headOffset >= 0) {
      putU32(out, headOffset + 8, 0);
      let sum = 0;
      for (let i = 0; i < out.length; i += 4) {
        const v = ((out[i] << 24) | (out[i + 1] << 16) | (out[i + 2] << 8) | out[i + 3]) >>> 0;
        sum = (sum + v) >>> 0;
      }
      putU32(out, headOffset + 8, (0xB1B0AFBA - sum) >>> 0);
    }
    return out;
  }

  // ---------- ZIP ----------
  async function unzip(buf) {
    const b = new Uint8Array(buf);
    let eocd = -1;
    for (let i = b.length - 22; i >= 0 && i > b.length - 66000; i--) {
      if (b[i] === 0x50 && b[i + 1] === 0x4b && b[i + 2] === 0x05 && b[i + 3] === 0x06) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error("ZIP 结构异常（找不到中央目录）");
    const count = le16(b, eocd + 10);
    let off = le32(b, eocd + 16);
    const entries = [];
    for (let i = 0; i < count; i++) {
      if (le32(b, off) !== 0x02014b50) break;
      const method = le16(b, off + 10);
      const compSize = le32(b, off + 20);
      const nameLen = le16(b, off + 28);
      const extraLen = le16(b, off + 30);
      const cmtLen = le16(b, off + 32);
      const localOff = le32(b, off + 42);
      const name = new TextDecoder("utf-8").decode(b.subarray(off + 46, off + 46 + nameLen));
      const lNameLen = le16(b, localOff + 26);
      const lExtraLen = le16(b, localOff + 28);
      const dataOff = localOff + 30 + lNameLen + lExtraLen;
      const raw = b.subarray(dataOff, dataOff + compSize);
      entries.push({ name, method, raw });
      off += 46 + nameLen + extraLen + cmtLen;
    }
    return entries;
  }

  // ---------- WOFF2 ----------
  let woff2Promise = null;
  function loadWoff2() {
    if (woff2Promise) return woff2Promise;
    woff2Promise = new Promise((resolve, reject) => {
      if (window.Module && typeof window.Module.decompress === "function") {
        resolve(window.Module);
        return;
      }
      window.Module = window.Module || {};
      window.Module.onRuntimeInitialized = function () {
        if (typeof window.Module.decompress === "function") resolve(window.Module);
        else reject(new Error("WOFF2 解码器初始化失败（没有 decompress）"));
      };
      const s = document.createElement("script");
      s.src = "woff2.js";
      s.onerror = () => reject(new Error("WOFF2 解码器加载失败（woff2.js）"));
      document.head.appendChild(s);
    });
    return woff2Promise;
  }

  async function woff2ToSfnt(buf) {
    const M = await loadWoff2();
    const res = M.decompress(new Uint8Array(buf));
    if (!res || res === false) throw new Error("WOFF2 解码失败");
    const out = res instanceof Uint8Array ? res : new Uint8Array(res.buffer || res);
    if (out.length < 12) throw new Error("WOFF2 解码结果为空");
    return out;
  }

  // ---------- 空格字符检测（只提示，不改表） ----------
  function hasSpaceGlyph(sfnt) {
    try {
      const b = sfnt;
      const n = u16(b, 4);
      for (let i = 0; i < n; i++) {
        const rec = 12 + i * 16;
        if (tag4(b, rec) !== "cmap") continue;
        const off = u32(b, rec + 8);
        const cnt = u16(b, off + 2);
        for (let j = 0; j < cnt; j++) {
          const pid = u16(b, off + 4 + j * 8), eid = u16(b, off + 6 + j * 8);
          const subOff = off + u32(b, off + 8 + j * 8);
          const fmt = u16(b, subOff);
          if ((pid === 3 && (eid === 1 || eid === 10)) || pid === 0) {
            if (fmt === 4) {
              const segX2 = u16(b, subOff + 6);
              const endsOff = subOff + 14;
              const startsOff = endsOff + segX2 * 2 + 2;
              for (let k = 0; k < segX2; k++) {
                const s = u16(b, startsOff + k * 2), e = u16(b, endsOff + k * 2);
                if (s <= 0x20 && 0x20 <= e) return true;
              }
            } else if (fmt === 12) {
              const groups = u32(b, subOff + 12);
              for (let k = 0; k < groups; k++) {
                const g = subOff + 16 + k * 12;
                if (u32(b, g) <= 0x20 && 0x20 <= u32(b, g + 4)) return true;
              }
            }
          }
        }
        return false;
      }
    } catch (e) { }
    return true; // 检测失败就不提示
  }

  // ---------- 对外：判断 + 转换 ----------
  function kindOf(file) {
    const n = (file.name || "").toLowerCase();
    if (n.endsWith(".woff2")) return "woff2";
    if (n.endsWith(".woff")) return "woff";
    if (n.endsWith(".zip")) return "zip";
    return "ttf";
  }

  async function convertOne(file, notes, depth) {
    depth = depth || 0;
    const kind = kindOf(file);
    if (kind === "ttf") {
      try {
        if (/\.(ttf)$/i.test(file.name)) {
          const buf0 = await file.arrayBuffer();
          const p = patchSpaceGlyph(buf0);
          if (p.note && /空格/.test(p.note)) notes.push(baseName(file.name) + "：" + p.note);
          if (p.note === "已自动补空格") return [{ name: baseName(file.name) + ".ttf", file: new File([p.data], baseName(file.name) + ".ttf", { type: "font/ttf" }) }];
        }
      } catch (e) { }
      return [{ name: file.name, file }];
    }
    if (depth > 2) return [];

    if (kind === "zip") {
      const entries = await unzip(await file.arrayBuffer());
      const out = [];
      for (const e of entries) {
        if (!isFontName(e.name) || e.name.endsWith("/")) continue;
        let data;
        if (e.method === 0) data = e.raw;
        else if (e.method === 8) data = await inflate(e.raw, "deflate-raw");
        else { notes.push(e.name + "：压缩方式不支持（method " + e.method + "）"); continue; }
        const sub = new File([data], e.name.split("/").pop());
        const r = await convertOne(sub, notes, depth + 1);
        out.push(...r);
      }
      return out;
    }

    const buf = await file.arrayBuffer();
    let sfnt;
    if (kind === "woff") sfnt = await woffToSfnt(buf);
    else sfnt = await woff2ToSfnt(buf);
    const name = baseName(file.name) + ".ttf";
    const patch = patchSpaceGlyph(sfnt);
    if (patch.note) notes.push(baseName(file.name) + "：" + patch.note);
    return [{ name, file: new File([patch.data], name, { type: "font/ttf" }) }];
  }


  // ---------- 缺空格自动补（U+0020）----------
  function checksum(data) {
    let sum = 0;
    for (let i = 0; i < data.length; i += 4) {
      const v = (((data[i] || 0) << 24) | ((data[i + 1] || 0) << 16) | ((data[i + 2] || 0) << 8) | (data[i + 3] || 0)) >>> 0;
      sum = (sum + v) >>> 0;
    }
    return sum;
  }

  function parseSfnt(buf) {
    const b = new Uint8Array(buf);
    const flavor = u32(b, 0);
    const n = u16(b, 4);
    const tables = new Map();
    for (let i = 0; i < n; i++) {
      const rec = 12 + i * 16;
      const tag = tag4(b, rec);
      const off = u32(b, rec + 8), len = u32(b, rec + 12);
      tables.set(tag, b.slice(off, off + len));
    }
    return { flavor, tables };
  }

  function buildFromTables(flavor, tables) {
    const items = [];
    for (const [tag, data] of tables) {
      const t = new Uint8Array(4);
      for (let i = 0; i < 4; i++) t[i] = tag.charCodeAt(i);
      items.push({ tag: t, data, checksum: checksum(data) });
    }
    return buildSfnt(flavor, items);
  }

  // 把 cmap 里所有映射读成 Map<codepoint, glyphId>
  function cmapToMap(cmap) {
    const out = new Map();
    const n = u16(cmap, 2);
    let best = null, bestScore = -1;
    for (let i = 0; i < n; i++) {
      const rec = 4 + i * 8;
      const pid = u16(cmap, rec), eid = u16(cmap, rec + 2);
      const off = u32(cmap, rec + 4);
      const fmt = u16(cmap, off);
      const score = (pid === 3 && eid === 10) ? 5 : (pid === 3 && eid === 1) ? 4 : (pid === 0) ? 3 : 0;
      if (fmt !== 4 && fmt !== 12) continue;
      if (score > bestScore) { bestScore = score; best = { off, fmt }; }
    }
    if (!best) return null;
    if (best.fmt === 4) {
      const segX2 = u16(cmap, best.off + 6);
      const ends = best.off + 14;              // endCode[]
      const starts = ends + segX2 + 2;         // 跳过 reservedPad
      const deltas = starts + segX2;
      const ros = deltas + segX2;
      for (let k = 0; k < segX2 / 2; k++) {
        const s0 = u16(cmap, starts + k * 2), e0 = u16(cmap, ends + k * 2);
        const d = u16(cmap, deltas + k * 2), ro = u16(cmap, ros + k * 2);
        for (let c = s0; c <= e0 && c !== 0xFFFF; c++) {
          let g = 0;
          if (ro === 0) g = (c + d) & 0xFFFF;
          else {
            const gi = ros + k * 2 + ro + (c - s0) * 2;
            if (gi + 1 < cmap.length) {
              g = u16(cmap, gi);
              if (g) g = (g + d) & 0xFFFF;
            }
          }
          if (g) out.set(c, g);
        }
      }
    } else {
      const groups = u32(cmap, best.off + 12);
      for (let k = 0; k < groups; k++) {
        const g = best.off + 16 + k * 12;
        const s0 = u32(cmap, g), e0 = u32(cmap, g + 4), gg = u32(cmap, g + 8);
        for (let c = s0; c <= e0; c++) out.set(c, gg + (c - s0));
      }
    }
    return out;
  }

  function buildFmt12(map) {
    const cps = [...map.keys()].sort((a, b) => a - b);
    const groups = [];
    for (const cp of cps) {
      const gid = map.get(cp);
      const last = groups[groups.length - 1];
      if (last && cp === last[1] + 1 && gid === last[2] + (cp - last[0])) last[1] = cp;
      else groups.push([cp, cp, gid]);
    }
    const len = 16 + groups.length * 12;
    const out = new Uint8Array(len);
    putU16(out, 0, 12); putU16(out, 2, 0);
    putU32(out, 4, len); putU32(out, 8, 0);
    putU32(out, 12, groups.length);
    let o = 16;
    for (const [s0, e0, g] of groups) {
      putU32(out, o, s0); putU32(out, o + 4, e0); putU32(out, o + 8, g); o += 12;
    }
    const wrapped = new Uint8Array(12 + len);
    putU16(wrapped, 0, 0);
    putU16(wrapped, 2, 1);
    putU16(wrapped, 4, 3);
    putU16(wrapped, 6, 10);
    putU32(wrapped, 8, 12);
    wrapped.set(out, 12);
    return wrapped;
  }

  function buildFmt4(map) {
    const cps = [...map.keys()].filter(c => c <= 0xFFFF).sort((a, b) => a - b);
    const segs = [];
    for (const cp of cps) {
      const gid = map.get(cp);
      const d = (gid - cp) & 0xFFFF;
      const last = segs[segs.length - 1];
      if (last && cp === last[1] + 1 && d === last[2]) last[1] = cp;
      else segs.push([cp, cp, d]);
    }
    if (!segs.length) return null;
    if (segs[segs.length - 1][1] !== 0xFFFF) segs.push([0xFFFF, 0xFFFF, 1]);
    const n = segs.length;
    const len = 16 + n * 8;
    if (len > 65000) return null;
    const out = new Uint8Array(len);
    putU16(out, 0, 4); putU16(out, 2, len); putU16(out, 4, 0);
    putU16(out, 6, n * 2);
    let p2 = 1, sel = 0;
    while (p2 * 2 <= n) { p2 *= 2; sel++; }
    putU16(out, 8, p2 * 2); putU16(out, 10, sel); putU16(out, 12, n * 2 - p2 * 2);
    let o = 14;
    for (const s0 of segs) { putU16(out, o, s0[1]); o += 2; }
    putU16(out, o, 0); o += 2;
    for (const s0 of segs) { putU16(out, o, s0[0]); o += 2; }
    for (const s0 of segs) { putU16(out, o, s0[2]); o += 2; }
    for (let k = 0; k < n; k++) { putU16(out, o, 0); o += 2; }
    const wrapped = new Uint8Array(12 + len);
    putU16(wrapped, 0, 0);
    putU16(wrapped, 2, 1);
    putU16(wrapped, 4, 3);
    putU16(wrapped, 6, 1);
    putU32(wrapped, 8, 12);
    wrapped.set(out, 12);
    return wrapped;
  }

  function patchSpaceGlyph(buf) {
    const { flavor, tables } = parseSfnt(buf);
    const tagStr = String.fromCharCode((flavor >>> 24) & 255, (flavor >>> 16) & 255, (flavor >>> 8) & 255, flavor & 255);
    if (tagStr === "OTTO") return { data: new Uint8Array(buf), note: "CFF 字体未做空格修补" };
    for (const t of ["cmap", "glyf", "loca", "head", "hhea", "hmtx", "maxp"]) {
      if (!tables.has(t)) return { data: new Uint8Array(buf), note: "" };
    }
    const map = cmapToMap(tables.get("cmap"));
    if (!map) return { data: new Uint8Array(buf), note: "" };
    if (map.has(0x20)) {
      // 有映射但宽度是 0：等于没有空格，照样补
      const gid0 = map.get(0x20);
      const numH0 = u16(tables.get("hhea"), 34);
      const hm = tables.get("hmtx");
      let adv0 = 0;
      if (numH0 > 0) {
        if (gid0 < numH0) adv0 = u16(hm, gid0 * 4);
        else adv0 = u16(hm, (numH0 - 1) * 4);
      }
      if (adv0 > 0) return { data: new Uint8Array(buf), note: "" };
      map.delete(0x20);
    }
    if (!map.has(0x41)) return { data: new Uint8Array(buf), note: "缺空格，但没有拉丁字形，未自动补" };

    const head = tables.get("head"), maxp = tables.get("maxp"), hhea = tables.get("hhea");
    const hmtx = tables.get("hmtx"), glyf = tables.get("glyf"), loca = tables.get("loca");
    const upem = u16(head, 18) || 1000;
    const oldN = u16(maxp, 4);
    const newGid = oldN;
    const spaceW = Math.max(1, Math.round(upem * 0.25));

    const longLoca = u16(head, 50) === 1;
    const glyfLen = glyf.length;
    const pad = (!longLoca && (glyfLen % 2)) ? 1 : 0;
    const newGlyf = new Uint8Array(glyfLen + pad);
    newGlyf.set(glyf, 0);
    const newLoca = new Uint8Array(loca.length + (longLoca ? 4 : 2));
    newLoca.set(loca, 0);
    if (longLoca) putU32(newLoca, loca.length, glyfLen + pad);
    else putU16(newLoca, loca.length, (glyfLen + pad) / 2);

    const numH = u16(hhea, 34);
    const advs = [], lsbs = [];
    for (let i = 0; i < numH; i++) { advs.push(u16(hmtx, i * 4)); lsbs.push(u16(hmtx, i * 4 + 2)); }
    for (let i = numH; i < oldN; i++) { advs.push(advs[numH - 1] || spaceW); lsbs.push(u16(hmtx, numH * 4 + (i - numH) * 2)); }
    advs.push(spaceW); lsbs.push(0);
    const newHmtx = new Uint8Array((newGid + 1) * 4);
    for (let i = 0; i <= newGid; i++) { putU16(newHmtx, i * 4, advs[i] || 0); putU16(newHmtx, i * 4 + 2, lsbs[i] || 0); }
    const newHhea = hhea.slice();
    putU16(newHhea, 34, newGid + 1);

    const newMaxp = maxp.slice();
    putU16(newMaxp, 4, newGid + 1);

    let newPost = null;
    if (tables.has("post")) {
      const post = tables.get("post");
      if (u32(post, 0) === 0x00020000) {
        newPost = new Uint8Array(post.length + 2);
        newPost.set(post, 0);
        putU16(newPost, 32, u16(post, 32) + 1);
        putU16(newPost, post.length, 0);
      }
    }

    map.set(0x20, newGid);
    let newCmap = buildFmt4(map);
    if (!newCmap) newCmap = buildFmt12(map);
    if (!newCmap) return { data: new Uint8Array(buf), note: "cmap 太大，未自动补空格" };

    const outTables = new Map(tables);
    outTables.set("glyf", newGlyf);
    outTables.set("loca", newLoca);
    outTables.set("hmtx", newHmtx);
    outTables.set("hhea", newHhea);
    outTables.set("maxp", newMaxp);
    outTables.set("cmap", newCmap);
    if (newPost) outTables.set("post", newPost);

    return { data: buildFromTables(flavor, outTables), note: "已自动补空格" };
  }

  window.__fontconvDebug = function (buf) {
    const { flavor, tables } = parseSfnt(buf);
    const map = tables.has("cmap") ? cmapToMap(tables.get("cmap")) : null;
    return { flavor: flavor, tables: [...tables.keys()], mapSize: map ? map.size : null,
             has20: map ? map.has(0x20) : null, has41: map ? map.has(0x41) : null };
  };
  window.__fontconvPatch = function (buf) { return patchSpaceGlyph(buf); };

  window.FontConv = {
    needConvert(file) {
      const k = kindOf(file);
      return k !== "ttf";
    },
    async convertFiles(files) {
      const notes = [];
      const out = [];
      for (const f of files) {
        try {
          const r = await convertOne(f, notes);
          out.push(...r);
        } catch (e) {
          notes.push((f.name || "?") + "：转换失败（" + (e && e.message ? e.message : e) + "）");
        }
      }
      return { files: out, notes };
    },
  };
})();

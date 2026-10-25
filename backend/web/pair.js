'use strict';
const $ = id => document.getElementById(id);
const params = new URLSearchParams(location.hash.slice(1));
const manager = params.get('manager'), payload = params.get('offer');
// Remove the bootstrap credentials from history immediately. Reload requires a fresh offer.
history.replaceState(null, '', location.pathname);
let deadline = 0, stopped = false, busy = false, shownQR = false;
const terminal = (title, detail) => {
  stopped = true; $('qr').hidden = true; $('placeholder').hidden = false;
  $('visual').hidden = false; $('visual').className = 'qr complete';
  $('placeholder').textContent = title === '已安全绑定' ? '✓' : '!'; $('headline').textContent = title;
  $('detail').textContent = detail; $('decision').hidden = true; $('code').hidden = true;
  $('timer').textContent = ''; $('state').textContent = title;
};
async function request(path, body) {
  const response = await fetch(path, {method:'POST', cache:'no-store', credentials:'omit', redirect:'error',
    headers:{'Content-Type':'application/json', 'Authorization':'Pairing ' + manager}, body:JSON.stringify(body)});
  if (!response.ok) throw new Error(response.status === 410 ? 'expired' : 'unavailable');
  return response.json();
}
async function poll() {
  if (stopped || busy) return;
  busy = true;
  try {
    const data = await request('/pairing/offer', shownQR ? {} : {payload});
    deadline = data.expiresAt * 1000; $('endpoint').textContent = data.endpoint;
    $('role').textContent = data.role === 'admin' ? '管理员配对；实际控制仍须在主板单独启用。' : '只读配对，不会修改校园网或重启主板。';
    if (data.state === 'approved') return terminal('已安全绑定', '现在可回到 iPhone 查看主板状态。关闭此页不会中断连接。');
    if (data.state === 'rejected') return terminal('已拒绝绑定', '没有签发设备凭据。如需重新配对，请生成新二维码。');
    if (data.state === 'pending') {
      $('visual').hidden = true;
      $('qr').hidden = true; $('placeholder').hidden = false; $('placeholder').textContent = '等待核对';
      $('state').textContent = '需要你的确认'; $('headline').textContent = data.deviceName;
      $('detail').textContent = '请确认手机显示的六位验证码与下方一致，再批准。';
      $('code').textContent = data.verificationCode; $('code').hidden = false; $('decision').hidden = false;
    } else {
      if (data.qr) { $('qr').src = data.qr; $('qr').hidden = false; $('placeholder').hidden = true; shownQR = true; }
      $('state').textContent = '等待手机扫码';
    }
  } catch (error) {
    terminal(error.message === 'expired' ? '二维码已过期' : '配对页面不可用', '请在部署终端重新生成配对页。不会自动重试或签发凭据。');
  } finally { busy = false; }
}
async function decide(approve) {
  $('approve').disabled = $('reject').disabled = true;
  try { await request('/pairing/decision', {approve}); await poll(); }
  catch { terminal('确认结果未收到', '请检查手机状态；不要重复批准。已批准的凭据不会因关闭此页而撤销。'); }
}
$('approve').addEventListener('click', () => decide(true));
$('reject').addEventListener('click', () => decide(false));
if (!manager || !payload) terminal('请从部署终端打开', '此页面不包含有效的限时配对链接，请重新运行配对命令。');
else { poll(); setInterval(poll, 2000); }
setInterval(() => {
  if (stopped || !deadline) return;
  const left = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
  $('timer').textContent = Math.floor(left / 60) + ':' + String(left % 60).padStart(2, '0');
  if (!left) terminal('二维码已过期', '请在部署终端生成新二维码。未批准的请求不会获得访问权限。');
}, 1000);

// Pull feedback belongs to a single gesture, never to periodic background snapshots.
export class ManualRefresh {
  private pending = false;
  private sawLegacyStart = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  constructor(private send: () => void,
    private show: (pulling: boolean, feedback: string) => void,
    private schedule = setTimeout, private cancel = clearTimeout) {}

  start(demo: boolean) {
    if (demo || this.pending) return;
    this.pending = true; this.sawLegacyStart = false;
    this.show(true, '');
    this.timer = this.schedule(() => {
      this.pending = false;
      this.show(false, '未收到刷新完成确认，保留上次数据。');
    }, 20_000);
    this.send();
  }
  snapshot(refreshing: boolean, hasAcknowledgement: boolean) {
    // Backward compatible with enabled older native shells on this runtime.
    if (!this.pending || hasAcknowledgement) return;
    if (refreshing) this.sawLegacyStart = true;
    else if (this.sawLegacyStart) this.finish();
  }
  finish() {
    if (!this.pending) return;
    this.cancel(this.timer); this.pending = false;
    this.show(false, '');
  }
  dispose() { this.cancel(this.timer); this.pending = false; }
}

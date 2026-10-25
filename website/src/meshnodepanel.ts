import { GATEWAY_WARN_MS, RADIO_MODEL } from '../shared/contract.ts';
import { rangeForRssi } from '../shared/signalmap.ts';
import { MeshNode, meshNodeExtras, meshNodeSupport, type NodeLink } from './meshnode.ts';
import { syncRows } from './pages.ts';

const STATE_TEXT: Record<NodeLink['state'], string> = {
  connecting: 'connecting…',
  linking: 'handshake…',
  ready: 'linked',
  reconnecting: 'reconnecting…',
  closed: 'not connected',
};

/** A signal reading this old is shown as unknown (matches what the node reports). */
const SIGNAL_MAX_AGE_MS = 5000;
/** Automatic reconnection to remembered phones is tried at most this often while the gateway is down. */
const FALLBACK_RETRY_MS = 30_000;
const FRAME_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;

const ago = (at: number | null, now: number): string => {
  if (at === null) return '–';
  const ms = Math.max(0, now - at);
  return ms < 1000 ? 'just now' : ms < 60_000 ? `${(ms / 1000).toFixed(1)} s ago` : `${Math.round(ms / 60_000)} min ago`;
};

/** "-68 dBm · ≈ 2.2 m" with the dashboard's radio model, or null without a fresh reading. */
export function signalText(rssi: number | null, at: number | null, now: number): string | null {
  if (rssi === null || at === null || now - at > SIGNAL_MAX_AGE_MS) return null;
  const meters = rangeForRssi(RADIO_MODEL, rssi);
  return `${Math.round(rssi)} dBm · ≈ ${meters < 10 ? meters.toFixed(1) : Math.round(meters)} m`;
}

const PANEL_HTML = `
  <h3>This dashboard as a mesh node</h3>
  <p class="hint">The laptop's own Bluetooth joins the phones' mesh like another phone: it receives their reports, relays
    them between the phones it links, and shows them here. No gateway phone or network is needed near the laptop. When
    the gateway stops uploading, the dashboard switches to this path by itself where the browser allows it.</p>
  <p class="hint warn-text" data-text="support"></p>
  <p class="hint warn-text" data-text="extras"></p>
  <div class="node-controls">
    <label>Frame <input type="text" data-input="frame" spellcheck="false" /></label>
    <button type="button" data-action="add">Connect a phone…</button>
    <label class="toggle"><input type="checkbox" data-input="relay" checked /> Relay between phones</label>
  </div>
  <div class="tiles compact">
    <div class="tile" data-tile="node-links"><span class="tile-label">Linked phones</span><span class="tile-value">0</span><span class="tile-detail"></span></div>
    <div class="tile" data-tile="node-received"><span class="tile-label">Packets</span><span class="tile-value">0</span><span class="tile-detail"></span></div>
    <div class="tile" data-tile="node-relayed"><span class="tile-label">Relayed</span><span class="tile-value">0</span><span class="tile-detail"></span></div>
    <div class="tile" data-tile="node-uploaded"><span class="tile-label">Shown here</span><span class="tile-value">0</span><span class="tile-detail"></span></div>
  </div>
  <div class="table-wrap"><table><thead><tr>
    <th>Phone</th><th>Mesh ID</th><th>State</th><th>Signal · distance to laptop</th><th>Packets</th><th>Relayed</th><th>Last heard</th><th></th>
  </tr></thead><tbody data-rows="node-links"></tbody></table></div>
  <p class="hint" data-text="status"></p>`;

/** Network-page card that drives the dashboard's own mesh node, and the gateway fallback. */
export class MeshNodePanel {
  private node: MeshNode | null = null;
  private readonly frameInput: HTMLInputElement;
  private readonly addButton: HTMLButtonElement;
  private readonly relayInput: HTMLInputElement;
  private lastFallbackTry = 0;
  /** Set while an automatic reconnection to remembered phones is in progress. */
  fallbackActive = false;

  constructor(
    private readonly root: HTMLElement,
    private readonly defaultFrame: () => string,
    private readonly toast: (message: string, isError?: boolean) => void,
  ) {
    root.innerHTML = PANEL_HTML;
    this.frameInput = root.querySelector('[data-input="frame"]')!;
    this.addButton = root.querySelector('[data-action="add"]')!;
    this.relayInput = root.querySelector('[data-input="relay"]')!;
    this.frameInput.value = defaultFrame();

    const support = meshNodeSupport();
    root.querySelector('[data-text="support"]')!.textContent = support.ok ? '' : support.reason;
    this.addButton.disabled = !support.ok;
    const extras = meshNodeExtras();
    root.querySelector('[data-text="extras"]')!.textContent =
      support.ok && (!extras.signal || !extras.reconnect)
        ? 'This browser cannot ' +
          [!extras.signal && 'read Bluetooth signal strength (so the laptop\'s distance to phones is unknown)',
            !extras.reconnect && 'reconnect remembered phones by itself (fallback needs a click, and phones are picked again after a reload)']
            .filter(Boolean)
            .join(' or ') +
          '. Start the dashboard with "npm run dashboard" (Edge with Web Bluetooth extras), or turn on ' +
          'edge://flags/#enable-web-bluetooth-new-permissions-backend and restart the browser.'
        : '';

    this.addButton.addEventListener('click', () => void this.addPhone());
    this.relayInput.addEventListener('change', () => {
      if (this.node) this.node.relayEnabled = this.relayInput.checked;
    });
    this.frameInput.addEventListener('change', () => {
      const frame = this.frameInput.value.trim();
      if (FRAME_PATTERN.test(frame)) this.node?.setFrame(frame);
      else this.toast('Frame IDs are 1–64 letters, digits, ".", "_" or "-"', true);
    });
    this.render();
  }

  get nodeId(): string | null {
    return this.node?.deviceId ?? null;
  }

  get readyLinks(): number {
    return this.node?.readyCount ?? 0;
  }

  get supported(): boolean {
    return meshNodeSupport().ok;
  }

  /** Follows the dashboard's frame until the node is in use. */
  syncFrame(): void {
    if (!this.node && document.activeElement !== this.frameInput) this.frameInput.value = this.defaultFrame();
  }

  private ensureNode(): MeshNode | null {
    const frame = this.frameInput.value.trim();
    if (!FRAME_PATTERN.test(frame)) {
      this.toast('Set the frame the phones use first (the app\'s Network tab shows it).', true);
      return null;
    }
    if (!this.node) {
      this.node = new MeshNode(frame);
      this.node.relayEnabled = this.relayInput.checked;
      this.node.onChange = () => this.render();
    } else {
      this.node.setFrame(frame);
    }
    return this.node;
  }

  /** Opens the phone picker; must run from a click (browsers require a user gesture). */
  async addPhone(): Promise<void> {
    const node = this.ensureNode();
    if (!node) return;
    try {
      await node.addPhone();
    } catch (error) {
      // The picker throws NotFoundError when the user closes it without choosing.
      if ((error as DOMException).name !== 'NotFoundError') this.toast((error as Error).message, true);
    }
    this.render();
  }

  /**
   * Called once a second. When nothing has uploaded for a while (gateway phone down or out of
   * Wi-Fi), links to remembered phones over Bluetooth without a click, where the browser allows it.
   */
  checkFallback(gatewayAgeMs: number, live: boolean): void {
    const down = live && gatewayAgeMs > GATEWAY_WARN_MS;
    this.fallbackActive = false;
    if (!down || !this.supported || !meshNodeExtras().reconnect) return;
    if (this.readyLinks > 0) return;
    const now = Date.now();
    if (now - this.lastFallbackTry < FALLBACK_RETRY_MS) {
      this.fallbackActive = Boolean(this.node && this.node.linkList.length > 0);
      return;
    }
    this.lastFallbackTry = now;
    const node = this.ensureNode();
    if (!node) return;
    void node.reconnectKnown().then((started) => {
      if (started > 0) this.toast(`Gateway not uploading: reconnecting ${started} phone${started === 1 ? '' : 's'} over Bluetooth`);
      this.fallbackActive = node.linkList.length > 0;
      this.render();
    });
  }

  render(): void {
    const node = this.node;
    const now = Date.now();
    const links = node?.linkList ?? [];
    const ready = links.filter((link) => link.state === 'ready').length;
    const setTile = (name: string, value: string, detail: string): void => {
      const tile = this.root.querySelector(`[data-tile="${name}"]`)!;
      tile.querySelector('.tile-value')!.textContent = value;
      tile.querySelector('.tile-detail')!.textContent = detail;
    };
    setTile('node-links', String(ready), links.length > ready ? `${links.length - ready} not linked` : '');
    setTile('node-received', String(node?.stats.received ?? 0), node ? `${node.stats.duplicates} duplicates` : '');
    setTile('node-relayed', String(node?.stats.relayed ?? 0), node?.relayEnabled === false ? 'relaying off' : '');
    setTile('node-uploaded', String(node?.stats.uploaded ?? 0), node ? `last ${ago(node.stats.lastUploadAt, now)}` : '');

    const signalSupported = meshNodeExtras().signal;
    syncRows(
      this.root.querySelector<HTMLTableSectionElement>('[data-rows="node-links"]')!,
      links,
      (link) => link.key,
      (cells, link, row) => {
        cells[0].textContent = link.label ?? link.name;
        cells[1].textContent = link.deviceId ? link.deviceId.slice(0, 12) : '–';
        cells[1].title = link.deviceId ?? '';
        cells[2].textContent = link.error ? `${STATE_TEXT[link.state]} · ${link.error}` : STATE_TEXT[link.state];
        cells[2].className = link.error ? 'warn wrap' : link.state === 'ready' ? 'ok' : '';
        cells[3].textContent =
          signalText(link.rssi, link.rssiAt, now) ?? (signalSupported ? 'waiting for a reading' : 'not available in this browser');
        cells[3].title = 'Advertisement RSSI, smoothed; the distance uses the dashboard\'s radio model and is an estimate.';
        cells[4].textContent = String(link.received);
        cells[5].textContent = String(link.relayed);
        cells[6].textContent = ago(link.lastHeard, now);
        if (!cells[7].firstElementChild) {
          const remove = document.createElement('button');
          remove.type = 'button';
          remove.className = 'small';
          remove.textContent = 'Disconnect';
          remove.addEventListener('click', (event) => {
            event.stopPropagation();
            this.node?.remove(link.key);
          });
          cells[7].append(remove);
        }
        row.classList.toggle('faded', link.state !== 'ready');
      },
      'No phones linked yet. Choose "Connect a phone…" and pick a phone running MeshMapper with the mesh on.',
    );

    const status = this.root.querySelector('[data-text="status"]')!;
    status.textContent = node
      ? `This node is "${node.deviceId}" in frame ${node.frame}.` +
        (node.stats.uploadError ? ` Not shown on the dashboard: ${node.stats.uploadError}` : '') +
        (signalSupported
          ? ' The dashboard places the laptop from its signal readings to the phones; pin it as an anchor to fix it instead.'
          : ' Phones count it as a neighbor; pin it as an anchor to place it on the map.')
      : '';
    status.classList.toggle('warn-text', Boolean(node?.stats.uploadError));
  }
}

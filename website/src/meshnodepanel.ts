import { MeshNode, meshNodeSupport, type NodeLink } from './meshnode.ts';
import { syncRows } from './pages.ts';

const STATE_TEXT: Record<NodeLink['state'], string> = {
  connecting: 'connecting…',
  linking: 'handshake…',
  ready: 'linked',
  reconnecting: 'reconnecting…',
  closed: 'not connected',
};

const ago = (at: number | null, now: number): string => {
  if (at === null) return '–';
  const ms = Math.max(0, now - at);
  return ms < 1000 ? 'just now' : ms < 60_000 ? `${(ms / 1000).toFixed(1)} s ago` : `${Math.round(ms / 60_000)} min ago`;
};

const PANEL_HTML = `
  <h3>This dashboard as a mesh node</h3>
  <p class="hint">The laptop's own Bluetooth joins the phones' mesh like another phone: it receives their reports, relays
    them between the phones it links, and shows them here. No gateway phone or network is needed near the laptop.</p>
  <p class="hint warn-text" data-text="support"></p>
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
    <th>Phone</th><th>Mesh ID</th><th>State</th><th>Packets</th><th>Relayed</th><th>Last heard</th><th></th>
  </tr></thead><tbody data-rows="node-links"></tbody></table></div>
  <p class="hint" data-text="status"></p>`;

/** Network-page card that drives the dashboard's own mesh node. */
export class MeshNodePanel {
  private node: MeshNode | null = null;
  private readonly frameInput: HTMLInputElement;
  private readonly addButton: HTMLButtonElement;
  private readonly relayInput: HTMLInputElement;

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

    this.addButton.addEventListener('click', () => void this.addPhone());
    this.relayInput.addEventListener('change', () => {
      if (this.node) this.node.relayEnabled = this.relayInput.checked;
    });
    this.frameInput.addEventListener('change', () => {
      const frame = this.frameInput.value.trim();
      if (/^[A-Za-z0-9._-]{1,64}$/.test(frame)) this.node?.setFrame(frame);
      else this.toast('Frame IDs are 1–64 letters, digits, ".", "_" or "-"', true);
    });
    this.render();
  }

  /** Follows the dashboard's frame until the node is in use. */
  syncFrame(): void {
    if (!this.node && document.activeElement !== this.frameInput) this.frameInput.value = this.defaultFrame();
  }

  private async addPhone(): Promise<void> {
    const frame = this.frameInput.value.trim();
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(frame)) {
      this.toast('Set the frame the phones use first (the app\'s Network tab shows it).', true);
      return;
    }
    if (!this.node) {
      this.node = new MeshNode(frame);
      this.node.relayEnabled = this.relayInput.checked;
      this.node.onChange = () => this.render();
    } else {
      this.node.setFrame(frame);
    }
    try {
      await this.node.addPhone();
    } catch (error) {
      // The picker throws NotFoundError when the user closes it without choosing.
      if ((error as DOMException).name !== 'NotFoundError') this.toast((error as Error).message, true);
    }
    this.render();
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
        cells[3].textContent = String(link.received);
        cells[4].textContent = String(link.relayed);
        cells[5].textContent = ago(link.lastHeard, now);
        if (!cells[6].firstElementChild) {
          const remove = document.createElement('button');
          remove.type = 'button';
          remove.className = 'small';
          remove.textContent = 'Disconnect';
          remove.addEventListener('click', (event) => {
            event.stopPropagation();
            this.node?.remove(link.key);
          });
          cells[6].append(remove);
        }
        row.classList.toggle('faded', link.state !== 'ready');
      },
      'No phones linked yet. Choose "Connect a phone…" and pick a phone running MeshMapper with the mesh on.',
    );

    const status = this.root.querySelector('[data-text="status"]')!;
    status.textContent = node
      ? `This node is "${node.deviceId}" in frame ${node.frame}.` +
        (node.stats.uploadError ? ` Not shown on the dashboard: ${node.stats.uploadError}` : '') +
        ' Phones count it as a neighbor; pin it as an anchor to place it on the map.'
      : '';
    status.classList.toggle('warn-text', Boolean(node?.stats.uploadError));
  }
}

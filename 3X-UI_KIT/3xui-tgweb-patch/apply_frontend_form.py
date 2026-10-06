#!/usr/bin/env python3
from pathlib import Path
import sys
R=Path(sys.argv[1] if len(sys.argv)>1 else ".")
def rw(path,old,new):
 p=R/path; s=p.read_text()
 if s.count(old)!=1: raise SystemExit(f"{path}: anchor count {s.count(old)}")
 p.write_text(s.replace(old,new,1))
F="frontend/src/pages/clients/ClientFormModal.tsx"
rw(F,"  Switch,\n  Tabs,","  Switch,\n  Checkbox,\n  Tabs,")
rw(F,"  attach: number[];\n  detach: number[];\n  externalLinks: ExternalLinkInput[];",
     "  attach: number[];\n  detach: number[];\n  attachExternal: string[];\n  detachExternal: string[];\n  externalLinks: ExternalLinkInput[];")
rw(F,"  client: Record<string, unknown>;\n  inboundIds: number[];\n}",
     "  client: Record<string, unknown>;\n  inboundIds: number[];\n  externalInboundKeys: string[];\n}")
rw(F,"  attachedExternalLinks?: ExternalLink[];\n  attachedIds?: number[];",
     "  attachedExternalLinks?: ExternalLink[];\n  attachedIds?: number[];\n  attachedExternalInboundKeys?: string[];")
rw(F,"  attachedExternalLinks = [],\n  attachedIds = [],",
     "  attachedExternalLinks = [],\n  attachedIds = [],\n  attachedExternalInboundKeys = [],")
rw(F,"  inboundIds: [],\n  externalLinks: [],",
     "  inboundIds: [],\n  externalInboundKeys: [],\n  externalLinks: [],")
rw(F,"        inboundIds: Array.isArray(attachedIds) ? [...attachedIds] : [],\n        externalLinks: toExternalLinkRows(attachedExternalLinks),",
     "        inboundIds: Array.isArray(attachedIds) ? [...attachedIds] : [],\n        externalInboundKeys: [...attachedExternalInboundKeys],\n        externalLinks: toExternalLinkRows(attachedExternalLinks),")
rw(F,"      inboundIds: values.inboundIds,\n    });",
     "      inboundIds: values.inboundIds,\n      externalInboundKeys: values.externalInboundKeys,\n    });")
rw(F,
'''        const toAttach = [...next].filter((id) => !original.has(id));
        const toDetach = [...original].filter((id) => !next.has(id));
        msg = await save(clientPayload, {''',
'''        const toAttach = [...next].filter((id) => !original.has(id));
        const toDetach = [...original].filter((id) => !next.has(id));
        const originalExternal = new Set(attachedExternalInboundKeys || []);
        const nextExternal = new Set(values.externalInboundKeys || []);
        const attachExternal = [...nextExternal].filter((key) => !originalExternal.has(key));
        const detachExternal = [...originalExternal].filter((key) => !nextExternal.has(key));
        msg = await save(clientPayload, {''')
rw(F,"          attach: toAttach,\n          detach: toDetach,\n          externalLinks,",
     "          attach: toAttach,\n          detach: toDetach,\n          attachExternal,\n          detachExternal,\n          externalLinks,")
rw(F,"          { client: clientPayload, inboundIds: values.inboundIds },",
     "          { client: clientPayload, inboundIds: values.inboundIds, externalInboundKeys: values.externalInboundKeys || [] },")
rw(F,
'''                        />
                      </Form.Item>

                      <Form.Item>
                        <Switch''',
'''                        />
                        <div style={{ marginTop: 8 }}>
                          <Controller
                            name="externalInboundKeys"
                            control={methods.control}
                            render={({ field }) => (
                              <Tooltip title="External Telegram WebProxy. Does not create an Xray inbound.">
                                <Checkbox
                                  checked={(field.value || []).includes('tgweb')}
                                  onChange={(e) => field.onChange(e.target.checked ? ['tgweb'] : [])}
                                >
                                  Telegram WebProxy <Tag>External</Tag>
                                </Checkbox>
                              </Tooltip>
                            )}
                          />
                        </div>
                      </Form.Item>

                      <Form.Item>
                        <Switch''')
C="frontend/src/pages/clients/RowCells.tsx"
rw(C,
'''interface ClientInboundChipsProps {
  ids: number[];
  inboundsById: Record<number, InboundOption>;''',
'''interface ClientInboundChipsProps {
  ids: number[];
  externalKeys?: string[];
  inboundsById: Record<number, InboundOption>;''')
rw(C,
'''export const ClientInboundChips = memo(function ClientInboundChips({
  ids,
  inboundsById,''',
'''export const ClientInboundChips = memo(function ClientInboundChips({
  ids,
  externalKeys = [],
  inboundsById,''')
rw(C,
'''  if (ids.length === 0) return <span className="cell-empty">—</span>;''',
'''  if (ids.length === 0 && externalKeys.length === 0) return <span className="cell-empty">—</span>;''')
rw(C,
'''      {visible.map(chip)}
      {overflow.length > 0 && (''',
'''      {visible.map(chip)}
      {externalKeys.includes('tgweb') && (
        <Tooltip title="External Telegram WebProxy. Does not create an Xray inbound.">
          <Tag style={CHIP_STYLE}>Telegram WebProxy · External</Tag>
        </Tooltip>
      )}
      {overflow.length > 0 && (''')

P="frontend/src/pages/clients/ClientsPage.tsx"
rw(P,"  const [editingAttachedIds, setEditingAttachedIds] = useState<number[]>([]);\n  const [editingExternalLinks, setEditingExternalLinks] = useState<ExternalLink[]>([]);",
     "  const [editingAttachedIds, setEditingAttachedIds] = useState<number[]>([]);\n  const [editingExternalInboundKeys, setEditingExternalInboundKeys] = useState<string[]>([]);\n  const [editingExternalLinks, setEditingExternalLinks] = useState<ExternalLink[]>([]);")
rw(P,"      setEditingAttachedIds([...ids]);\n      setEditingExternalLinks(Array.isArray(full?.externalLinks) ? [...full.externalLinks] : []);",
     "      setEditingAttachedIds([...ids]);\n      setEditingExternalInboundKeys(Array.isArray(full?.externalInboundKeys) ? [...full.externalInboundKeys] : []);\n      setEditingExternalLinks(Array.isArray(full?.externalLinks) ? [...full.externalLinks] : []);")
rw(P,"            attach: number[];\n            detach: number[];\n            externalLinks: ExternalLinkInput[];",
     "            attach: number[];\n            detach: number[];\n            attachExternal: string[];\n            detachExternal: string[];\n            externalLinks: ExternalLinkInput[];")
rw(P,
'''      if (Array.isArray(meta.attach) && meta.attach.length > 0) {
        const r = await attach(emailKey, meta.attach);
        if (!r?.success) return r;
      }
      if (Array.isArray(meta.detach) && meta.detach.length > 0) {
        const r = await detach(emailKey, meta.detach);
        if (!r?.success) return r;
      }''',
'''      if (meta.attach.length > 0 || meta.attachExternal.length > 0) {
        const r = await attach(emailKey, meta.attach, meta.attachExternal);
        if (!r?.success) return r;
      }
      if (meta.detach.length > 0 || meta.detachExternal.length > 0) {
        const r = await detach(emailKey, meta.detach, meta.detachExternal);
        if (!r?.success) return r;
      }''')
rw(P,
'''              ids={record.inboundIds || EMPTY_INBOUND_IDS}
              inboundsById={inboundsById}''',
'''              ids={record.inboundIds || EMPTY_INBOUND_IDS}
              externalKeys={record.externalInboundKeys || []}
              inboundsById={inboundsById}''')
rw(P,"            attachedIds={editingAttachedIds}",
     "            attachedIds={editingAttachedIds}\n            attachedExternalInboundKeys={editingExternalInboundKeys}")
print("frontend form patch applied")

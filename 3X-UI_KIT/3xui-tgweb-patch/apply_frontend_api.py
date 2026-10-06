#!/usr/bin/env python3
from pathlib import Path
import sys
R=Path(sys.argv[1] if len(sys.argv)>1 else ".")
def rw(path,old,new):
 p=R/path; s=p.read_text()
 if s.count(old)!=1: raise SystemExit(f"{path}: anchor count {s.count(old)}")
 p.write_text(s.replace(old,new,1))
rw("frontend/src/schemas/client.ts",
'''    inboundIds: nullableNumberArray.optional(),
    traffic: ClientTrafficSchema.nullable().optional(),''',
'''    inboundIds: nullableNumberArray.optional(),
    externalInboundKeys: nullableStringArray.optional(),
    traffic: ClientTrafficSchema.nullable().optional(),''')
rw("frontend/src/schemas/client.ts",
'''  inboundIds: nullableNumberArray,
  externalLinks: ExternalLinkListSchema.optional(),''',
'''  inboundIds: nullableNumberArray,
  externalInboundKeys: nullableStringArray.optional(),
  externalLinks: ExternalLinkListSchema.optional(),''')
rw("frontend/src/schemas/client.ts",
'''  enable: z.boolean(),
  inboundIds: z.array(z.number()),
});''',
'''  enable: z.boolean(),
  inboundIds: z.array(z.number()),
  externalInboundKeys: z.array(z.string()).default([]),
});''')
rw("frontend/src/hooks/useClients.ts",
'''  const attachMut = useMutation({
    mutationFn: ({ email, inboundIds }: { email: string; inboundIds: number[] }) =>
      HttpUtil.post(
        `/panel/api/clients/${encodeURIComponent(email)}/attach`,
        { inboundIds },''',
'''  const attachMut = useMutation({
    mutationFn: ({ email, inboundIds, externalInboundKeys }: {
      email: string; inboundIds: number[]; externalInboundKeys?: string[];
    }) =>
      HttpUtil.post(
        `/panel/api/clients/${encodeURIComponent(email)}/attach`,
        { inboundIds, externalInboundKeys: externalInboundKeys ?? [] },''')
rw("frontend/src/hooks/useClients.ts",
'''  const detachMut = useMutation({
    mutationFn: ({ email, inboundIds }: { email: string; inboundIds: number[] }) =>
      HttpUtil.post(
        `/panel/api/clients/${encodeURIComponent(email)}/detach`,
        { inboundIds },''',
'''  const detachMut = useMutation({
    mutationFn: ({ email, inboundIds, externalInboundKeys }: {
      email: string; inboundIds: number[]; externalInboundKeys?: string[];
    }) =>
      HttpUtil.post(
        `/panel/api/clients/${encodeURIComponent(email)}/detach`,
        { inboundIds, externalInboundKeys: externalInboundKeys ?? [] },''')
rw("frontend/src/hooks/useClients.ts",
'''  const attach = useCallback(
    (email: string, inboundIds: number[]) => {
      if (!email) return Promise.resolve(null as unknown as Msg<unknown>);
      return attachMut.mutateAsync({ email, inboundIds });
    },''',
'''  const attach = useCallback(
    (email: string, inboundIds: number[], externalInboundKeys: string[] = []) => {
      if (!email) return Promise.resolve(null as unknown as Msg<unknown>);
      return attachMut.mutateAsync({ email, inboundIds, externalInboundKeys });
    },''')
rw("frontend/src/hooks/useClients.ts",
'''  const detach = useCallback(
    (email: string, inboundIds: number[]) => {
      if (!email) return Promise.resolve(null as unknown as Msg<unknown>);
      return detachMut.mutateAsync({ email, inboundIds });
    },''',
'''  const detach = useCallback(
    (email: string, inboundIds: number[], externalInboundKeys: string[] = []) => {
      if (!email) return Promise.resolve(null as unknown as Msg<unknown>);
      return detachMut.mutateAsync({ email, inboundIds, externalInboundKeys });
    },''')
print("frontend schema/hooks patch applied")

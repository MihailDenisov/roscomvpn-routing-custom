#!/usr/bin/env python3
from pathlib import Path
import sys
R=Path(sys.argv[1] if len(sys.argv)>1 else ".")
def rw(path,old,new):
 p=R/path; s=p.read_text()
 if s.count(old)!=1: raise SystemExit(f"{path}: anchor count {s.count(old)}")
 p.write_text(s.replace(old,new,1))
rw("internal/web/service/client_lookup.go",
'''	trafficByEmail := make(map[string]*xray.ClientTraffic, len(emails))''',
'''	externalAttachments, err := s.externalInboundMap(clientIds)
	if err != nil {
		return nil, err
	}

	trafficByEmail := make(map[string]*xray.ClientTraffic, len(emails))''')
rw("internal/web/service/client_lookup.go",
'''		out = append(out, ClientWithAttachments{
			ClientRecord: rows[i],
			InboundIds:   attachments[rows[i].Id],
			Traffic:      trafficByEmail[rows[i].Email],
		})''',
'''		out = append(out, ClientWithAttachments{
			ClientRecord:        rows[i],
			InboundIds:          attachments[rows[i].Id],
			ExternalInboundKeys: externalAttachments[rows[i].Id],
			Traffic:             trafficByEmail[rows[i].Email],
		})''')
rw("internal/web/service/client_paging.go",
'''	InboundIds   []int               `json:"inboundIds" example:"[3,5]"`
	Traffic      *xray.ClientTraffic `json:"traffic,omitempty"`''',
'''	InboundIds          []int               `json:"inboundIds" example:"[3,5]"`
	ExternalInboundKeys []string            `json:"externalInboundKeys,omitempty"`
	Traffic             *xray.ClientTraffic `json:"traffic,omitempty"`''')
rw("internal/web/service/client_paging.go",
'''	trafficByEmail := make(map[string]*xray.ClientTraffic, len(emails))''',
'''	externalAttachments, err := (&ClientService{}).externalInboundMap(ids)
	if err != nil {
		return nil, err
	}

	trafficByEmail := make(map[string]*xray.ClientTraffic, len(emails))''')
rw("internal/web/service/client_paging.go",
'''		items = append(items, toClientSlim(ClientWithAttachments{
			ClientRecord: *rec,
			InboundIds:   attachments[rec.Id],
			Traffic:      trafficByEmail[rec.Email],
		}))''',
'''		items = append(items, toClientSlim(ClientWithAttachments{
			ClientRecord:        *rec,
			InboundIds:          attachments[rec.Id],
			ExternalInboundKeys: externalAttachments[rec.Id],
			Traffic:             trafficByEmail[rec.Email],
		}))''')
rw("internal/web/service/client_paging.go",
'''		InboundIds:   c.InboundIds,''',
'''		InboundIds:          c.InboundIds,
		ExternalInboundKeys: c.ExternalInboundKeys,''')
rw("internal/web/service/client_portable.go",
'''		out = append(out, ClientCreatePayload{
			Client:     *client,
			InboundIds: attachments[rows[i].Id],
			LimitHwid:  rows[i].LimitHwid,
			Traffic:    trafficByEmail[rows[i].Email],
		})''',
'''		externalKeys, err := s.GetExternalInboundKeysForRecord(rows[i].Id)
		if err != nil {
			return nil, err
		}
		out = append(out, ClientCreatePayload{
			Client:              *client,
			InboundIds:          attachments[rows[i].Id],
			ExternalInboundKeys: externalKeys,
			LimitHwid:           rows[i].LimitHwid,
			Traffic:             trafficByEmail[rows[i].Email],
		})''')
print("backend list/export patch applied")

#!/usr/bin/env python3
from pathlib import Path
import sys
R=Path(sys.argv[1] if len(sys.argv)>1 else ".")
def rw(path,old,new):
 p=R/path; s=p.read_text()
 if s.count(old)!=1: raise SystemExit(f"{path}: anchor count {s.count(old)}")
 p.write_text(s.replace(old,new,1))
rw("internal/web/service/client.go",
'''type ClientWithAttachments struct {
	model.ClientRecord
	InboundIds []int               `json:"inboundIds"`
	Traffic    *xray.ClientTraffic `json:"traffic,omitempty"`
}''',
'''type ClientWithAttachments struct {
	model.ClientRecord
	InboundIds          []int               `json:"inboundIds"`
	ExternalInboundKeys []string            `json:"externalInboundKeys"`
	Traffic             *xray.ClientTraffic `json:"traffic,omitempty"`
}''')
rw("internal/web/service/client.go",
'''	extras := struct {
		InboundIds []int               `json:"inboundIds"`
		Traffic    *xray.ClientTraffic `json:"traffic,omitempty"`
	}{InboundIds: c.InboundIds, Traffic: c.Traffic}''',
'''	extras := struct {
		InboundIds          []int               `json:"inboundIds"`
		ExternalInboundKeys []string            `json:"externalInboundKeys"`
		Traffic             *xray.ClientTraffic `json:"traffic,omitempty"`
	}{InboundIds: c.InboundIds, ExternalInboundKeys: c.ExternalInboundKeys, Traffic: c.Traffic}''')
rw("internal/web/service/client.go",
'''type ClientCreatePayload struct {
	Client     model.Client           `json:"client"`
	InboundIds []int                  `json:"inboundIds"`
	LimitHwid  int                    `json:"-"`
	Traffic    *ClientPortableTraffic `json:"traffic,omitempty"`
}''',
'''type ClientCreatePayload struct {
	Client              model.Client           `json:"client"`
	InboundIds          []int                  `json:"inboundIds"`
	ExternalInboundKeys []string               `json:"externalInboundKeys,omitempty"`
	LimitHwid           int                    `json:"-"`
	Traffic             *ClientPortableTraffic `json:"traffic,omitempty"`
}''')
rw("internal/web/service/client.go",
'''		InboundIds []int                  `json:"inboundIds"`
		Traffic    *ClientPortableTraffic `json:"traffic"`''',
'''		InboundIds          []int                  `json:"inboundIds"`
		ExternalInboundKeys []string               `json:"externalInboundKeys"`
		Traffic             *ClientPortableTraffic `json:"traffic"`''')
rw("internal/web/service/client.go",
'''	p.InboundIds = raw.InboundIds
	p.LimitHwid = withHwid.LimitHwid''',
'''	p.InboundIds = raw.InboundIds
	p.ExternalInboundKeys = raw.ExternalInboundKeys
	p.LimitHwid = withHwid.LimitHwid''')
rw("internal/web/service/client.go",
'''		InboundIds []int                  `json:"inboundIds"`
		Traffic    *ClientPortableTraffic `json:"traffic,omitempty"`''',
'''		InboundIds          []int                  `json:"inboundIds"`
		ExternalInboundKeys []string               `json:"externalInboundKeys,omitempty"`
		Traffic             *ClientPortableTraffic `json:"traffic,omitempty"`''')
rw("internal/web/service/client.go",
'''		InboundIds: p.InboundIds,
		Traffic:    p.Traffic,''',
'''		InboundIds:          p.InboundIds,
		ExternalInboundKeys: p.ExternalInboundKeys,
		Traffic:             p.Traffic,''')

rw("internal/web/controller/client.go",
'''	inboundIds, err := a.clientService.GetInboundIdsForRecord(rec.Id)
	if err != nil {
		return nil, err
	}
	externalLinks, err := a.clientService.GetExternalLinksForRecord(rec.Id)''',
'''	inboundIds, err := a.clientService.GetInboundIdsForRecord(rec.Id)
	if err != nil {
		return nil, err
	}
	externalInboundKeys, err := a.clientService.GetExternalInboundKeysForRecord(rec.Id)
	if err != nil {
		return nil, err
	}
	externalLinks, err := a.clientService.GetExternalLinksForRecord(rec.Id)''')
rw("internal/web/controller/client.go",
'''		"client":           rec,
		"inboundIds":       inboundIds,
		"externalLinks":    externalLinks,''',
'''		"client":              rec,
		"inboundIds":          inboundIds,
		"externalInboundKeys": externalInboundKeys,
		"externalLinks":       externalLinks,''')
rw("internal/web/controller/client.go",
'''	if err != nil {
		jsonMsg(c, I18nWeb(c, "somethingWentWrong"), err)
		return
	}
	jsonMsgObj(c, I18nWeb(c, "pages.inbounds.toasts.inboundClientAddSuccess"), pendingNodeObj(a.inboundService.AnyNodePending(payload.InboundIds)), nil)
}''',
'''	if err != nil {
		jsonMsg(c, I18nWeb(c, "somethingWentWrong"), err)
		return
	}
	if err := a.clientService.AttachExternalByEmail(payload.Client.Email, payload.ExternalInboundKeys); err != nil {
		jsonMsg(c, I18nWeb(c, "somethingWentWrong"), err)
		return
	}
	jsonMsgObj(c, I18nWeb(c, "pages.inbounds.toasts.inboundClientAddSuccess"), pendingNodeObj(a.inboundService.AnyNodePending(payload.InboundIds)), nil)
}''')
rw("internal/web/controller/client.go",
'''type attachDetachBody struct {
	InboundIds []int `json:"inboundIds"`
}''',
'''type attachDetachBody struct {
	InboundIds          []int    `json:"inboundIds"`
	ExternalInboundKeys []string `json:"externalInboundKeys"`
}''')
rw("internal/web/controller/client.go",
'''	needRestart, err := a.clientService.AttachByEmail(&a.inboundService, email, body.InboundIds)
	if needRestart {''',
'''	needRestart := false
	var err error
	if len(body.InboundIds) > 0 {
		needRestart, err = a.clientService.AttachByEmail(&a.inboundService, email, body.InboundIds)
	}
	if err == nil {
		err = a.clientService.AttachExternalByEmail(email, body.ExternalInboundKeys)
	}
	if needRestart {''')
rw("internal/web/controller/client.go",
'''	needRestart, err := a.clientService.DetachByEmailMany(&a.inboundService, email, body.InboundIds)
	if needRestart {''',
'''	needRestart := false
	var err error
	if len(body.InboundIds) > 0 {
		needRestart, err = a.clientService.DetachByEmailMany(&a.inboundService, email, body.InboundIds)
	}
	if err == nil {
		err = a.clientService.DetachExternalByEmail(email, body.ExternalInboundKeys)
	}
	if needRestart {''')
print("backend API patch applied")

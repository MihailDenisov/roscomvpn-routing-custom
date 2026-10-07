#!/usr/bin/env python3
from pathlib import Path
import sys
R=Path(sys.argv[1] if len(sys.argv)>1 else ".")
test=r'''package service

import (
	"path/filepath"
	"testing"

	"github.com/mhsanaei/3x-ui/v3/internal/database"
	"github.com/mhsanaei/3x-ui/v3/internal/database/dbtest"
	"github.com/mhsanaei/3x-ui/v3/internal/database/model"
)

func TestExternalInboundAttachDetachIsIdempotent(t *testing.T) {
	dbtest.InitDB(t, filepath.Join(t.TempDir(), "x-ui.db"))
	db := database.GetDB()
	rec := model.ClientRecord{Email: "mv"}
	if err := db.Create(&rec).Error; err != nil { t.Fatal(err) }
	s := &ClientService{}

	if err := s.AttachExternalByEmail("mv", []string{"tgweb", "tgweb"}); err != nil { t.Fatal(err) }
	keys, err := s.GetExternalInboundKeysForRecord(rec.Id)
	if err != nil { t.Fatal(err) }
	if len(keys) != 1 || keys[0] != "tgweb" { t.Fatalf("keys=%v", keys) }

	if err := s.DetachExternalByEmail("mv", []string{"tgweb"}); err != nil { t.Fatal(err) }
	if err := s.DetachExternalByEmail("mv", []string{"tgweb"}); err != nil { t.Fatal(err) }
	keys, err = s.GetExternalInboundKeysForRecord(rec.Id)
	if err != nil { t.Fatal(err) }
	if len(keys) != 0 { t.Fatalf("keys after detach=%v", keys) }
}

func TestExternalInboundRejectsUnknownProvider(t *testing.T) {
	dbtest.InitDB(t, filepath.Join(t.TempDir(), "x-ui.db"))
	db := database.GetDB()
	rec := model.ClientRecord{Email: "mv"}
	if err := db.Create(&rec).Error; err != nil { t.Fatal(err) }
	s := &ClientService{}
	if err := s.AttachExternalByEmail("mv", []string{"vless"}); err == nil {
		t.Fatal("unknown external provider accepted")
	}
	var n int64
	if err := db.Model(&model.ClientExternalInbound{}).Count(&n).Error; err != nil { t.Fatal(err) }
	if n != 0 { t.Fatalf("unexpected external rows=%d", n) }
}
'''
p=R/"internal/web/service/client_external_inbound_test.go"
if p.exists(): raise SystemExit("test file already exists")
p.write_text(test)
print("tests added")

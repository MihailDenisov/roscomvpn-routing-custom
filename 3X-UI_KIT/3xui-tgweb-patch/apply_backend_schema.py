#!/usr/bin/env python3
from pathlib import Path
import sys
R=Path(sys.argv[1] if len(sys.argv)>1 else ".")
def rw(path, old, new):
 p=R/path; s=p.read_text()
 if s.count(old)!=1: raise SystemExit(f"{path}: anchor count={s.count(old)}")
 p.write_text(s.replace(old,new,1))
rw("internal/database/model/model.go",
'func (ClientInbound) TableName() string { return "client_inbounds" }\n',
'''func (ClientInbound) TableName() string { return "client_inbounds" }

type ClientExternalInbound struct {
	ClientId int `json:"clientId" gorm:"primaryKey;column:client_id;index"`
	Provider string `json:"provider" gorm:"primaryKey;column:provider;size:64"`
	CreatedAt int64 `json:"createdAt" gorm:"autoCreateTime:milli"`
}
func (ClientExternalInbound) TableName() string { return "client_external_inbounds" }
''')
for path in ("internal/database/db.go","internal/database/migrate_data.go"):
 rw(path,"\t\t&model.ClientInbound{},\n","\t\t&model.ClientInbound{},\n\t\t&model.ClientExternalInbound{},\n")
rw("internal/web/service/client_crud.go",
'''		if err := tx.Where("client_id = ?", id).Delete(&model.ClientInbound{}).Error; err != nil {
			return err
		}
		if err := tx.Where("client_id = ?", id).Delete(&model.ClientExternalLink{}).Error; err != nil {''',
'''		if err := tx.Where("client_id = ?", id).Delete(&model.ClientInbound{}).Error; err != nil {
			return err
		}
		if err := tx.Where("client_id = ?", id).Delete(&model.ClientExternalInbound{}).Error; err != nil {
			return err
		}
		if err := tx.Where("client_id = ?", id).Delete(&model.ClientExternalLink{}).Error; err != nil {''')
svc=r'''package service

import (
 "errors"
 "sort"
 "strings"
 "time"

 "github.com/mhsanaei/3x-ui/v3/internal/database"
 "github.com/mhsanaei/3x-ui/v3/internal/database/model"
 "github.com/mhsanaei/3x-ui/v3/internal/util/common"
 "gorm.io/gorm"
 "gorm.io/gorm/clause"
)
const ExternalInboundTgWeb = "tgweb"

func normalizeExternalInboundKeys(keys []string) ([]string,error) {
 seen:=map[string]struct{}{}; out:=make([]string,0,len(keys))
 for _,raw:=range keys {
  key:=strings.ToLower(strings.TrimSpace(raw)); if key=="" { continue }
  if key!=ExternalInboundTgWeb { return nil,common.NewError("unknown external inbound provider:",key) }
  if _,ok:=seen[key]; ok { continue }; seen[key]=struct{}{}; out=append(out,key)
 }
 sort.Strings(out); return out,nil
}
func (s *ClientService) GetExternalInboundKeysForRecord(id int)([]string,error){
 var keys []string
 err:=database.GetDB().Model(&model.ClientExternalInbound{}).Where("client_id = ?",id).
  Order("provider ASC").Pluck("provider",&keys).Error
 return keys,err
}
func (s *ClientService) externalInboundMap(ids []int)(map[int][]string,error){
 out:=make(map[int][]string,len(ids)); if len(ids)==0{return out,nil}
 for _,batch:=range chunkInts(ids,sqlInChunk){
  var rows []model.ClientExternalInbound
  if err:=database.GetDB().Where("client_id IN ?",batch).
   Order("client_id ASC, provider ASC").Find(&rows).Error; err!=nil{return nil,err}
  for _,row:=range rows { out[row.ClientId]=append(out[row.ClientId],row.Provider) }
 }
 return out,nil
}
func (s *ClientService) AttachExternalByEmail(email string,keys []string)error{
 keys,err:=normalizeExternalInboundKeys(keys); if err!=nil||len(keys)==0{return err}
 rec,err:=s.GetRecordByEmail(nil,email); if err!=nil{return err}
 now:=time.Now().UnixMilli(); rows:=make([]model.ClientExternalInbound,0,len(keys))
 for _,key:=range keys { rows=append(rows,model.ClientExternalInbound{ClientId:rec.Id,Provider:key,CreatedAt:now}) }
 return database.GetDB().Clauses(clause.OnConflict{DoNothing:true}).Create(&rows).Error
}
func (s *ClientService) DetachExternalByEmail(email string,keys []string)error{
 keys,err:=normalizeExternalInboundKeys(keys); if err!=nil||len(keys)==0{return err}
 rec,err:=s.GetRecordByEmail(nil,email)
 if err!=nil { if errors.Is(err,gorm.ErrRecordNotFound){return nil}; return err }
 return database.GetDB().Where("client_id = ? AND provider IN ?",rec.Id,keys).
  Delete(&model.ClientExternalInbound{}).Error
}
func (s *ClientService) DeleteExternalByClientID(id int)error{
 if id<=0{return nil}
 return database.GetDB().Where("client_id = ?",id).Delete(&model.ClientExternalInbound{}).Error
}
'''
p=R/"internal/web/service/client_external_inbound.go"
if p.exists(): raise SystemExit("client_external_inbound.go already exists")
p.write_text(svc)
print("backend schema patch applied")

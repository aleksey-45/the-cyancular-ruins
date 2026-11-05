class_name PickupState
extends RefCounted

# 地面武器的权威快照记录：固定 4 槽，服务端每 tick 给出，客户端按同序读取。

const POS := 0
const VEL := 1
const TYPE_ID := 2
const MAG := 3
const SIZE := 4

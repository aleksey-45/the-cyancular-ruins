class_name ActorInput
extends NativeActorInput

# 一次共享步进的值输入；本地和网络输入都先打包，再在这里统一应用控制锁。
# 持续输入原值供权威快照延续使用，模拟只读取已处理控制锁的字段。
const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8
const BIT_RELOAD := 16
const BIT_PICKUP := 32
const BIT_DROP := 64
const BIT_HASTE := 128
const BIT_REWIND := 256

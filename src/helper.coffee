moment = require('moment')
{conditionCheck} = require('./trigger')

updateLockStatus = (curStatus, target, config) ->
  return [] unless curStatus
  ret = []
  for id, cfg of config
    unlockable = true
    if cfg.cond? then unlockable = unlockable and conditionCheck(cfg.cond, target)
    if unlockable and not curStatus[id]? then ret.push(+id)
  return ret
exports.updateLockStatus = updateLockStatus

currentTime = (needObject) ->
  obj = moment().zone("+08:00")
  if needObject
    return obj
  else
    return obj.format(time_format)
exports.currentTime = currentTime

diffDate = (date, today) ->
  return null unless date
  date = moment(date).zone("+08:00").startOf('day') if date
  today = moment(today).zone("+08:00").startOf('day')
  return moment.duration(today.diff(date)).asDays()
exports.diffDate = diffDate

exports.calculateTotalItemXP = (item) ->
  return 0 unless item.xp?
  levelTable = [0, 1, 2, 3, 4]
  upgrade = queryTable(TABLE_UPGRADE)
  xp = item.xp
  for i, cfg of upgrade when levelTable[item.quality] <= i < item.rank
    xp += cfg.xp
  return xp

initCampaign = (me, allCampaign, abIndex) ->
  ret = []
  for key, e of allCampaign when me.getType() is e.storeType
    if e.prev? and me[e.prev]? and me[e.prev].status isnt 'Done'
      delete me[key]
      return []
    if not me.flags? then me.attrSave('flags', {})
    if e.flag? and not me.flags[e.flag]
      delete me[key]
      return []
    if e.daily and me[key]?.date? and diffDate(me[key].date, currentTime()) isnt 0
      delete me[key]

    flag = false
    if not me[key]?
      me.attrSave(key, {})
      flag = true
    if e.daily
      if not me[key].date or diffDate(me[key].date, currentTime()) isnt 0
        me[key].status = 'Ready'
        me[key].date = currentTime()
        flag = true
        if key is 'event_daily'
          me[key].rank = me.battleForce/24 - 3
          if me[key].rank < 1 then me[key].rank = 1
          me[key].reward = [{type: PRIZETYPE_GOLD, count: Math.floor(me[key].rank*18)}]

    if e.quest and Array.isArray(e.quest) and not me[key].quest?
      me[key].quest = shuffle(e.quest, Math.random()).slice(0, e.steps)
      me[key].step = 0
      goldCount = Math.ceil(me[key].rank*6)
      diamondCount = Math.ceil(me[key].rank/10)
      goldCount = Math.floor(me[key].rank*6)
      me[key].stepPrize = [
        [{type: PRIZETYPE_GOLD, count: goldCount}, {type: PRIZETYPE_ITEM, value: 0, count: diamondCount}],
        [{type: PRIZETYPE_GOLD, count: goldCount}, {type: PRIZETYPE_ITEM, value: 0, count: diamondCount}, {type: PRIZETYPE_ITEM, value: 534, count: 5}],
        [{type: PRIZETYPE_GOLD, count: goldCount}, {type: PRIZETYPE_ITEM, value: 0, count: diamondCount}, {type: PRIZETYPE_ITEM, value: 535, count: 2}],
        [{type: PRIZETYPE_GOLD, count: goldCount}, {type: PRIZETYPE_ITEM, value: 0, count: diamondCount}, {type: PRIZETYPE_ITEM, value: 536, count: 1}]
      ]
    quest = me[key].quest
    if Array.isArray(quest)
      quest = quest[me[key].step]
    switch me[key].status
      when 'Claimed'
        if quest? then delete me.quests[quest]
        me[key].step++
        if me[key].step == e.steps
          me[key].status = 'Complete'
        else if me[key].step > e.steps
          me[key].status = 'Done'
        else
          me[key].status = 'Ready'
          quest = me[key].quest
          if Array.isArray(quest)
            quest = quest[me[key].step]
          if quest? then delete me.quests[quest]
          return ret.concat(initCampaign(me, allCampaign, abIndex))
      when 'Ready'
        if quest?
          if me.isQuestAchieved(quest)
            me[key].status = 'Complete'
          else if not me.quests[quest]
            ret = ret.concat(me.acceptQuest(quest))
  evt = {
    NTF: Event_UpdateDailyQuest,
    arg: { stp: me.event_daily.step, prz: me.event_daily.reward }
  }
  if me.event_daily.quest[me.event_daily.step]?
    evt.arg.qst = me.event_daily.quest[me.event_daily.step]
  if me.event_daily.stepPrize[me.event_daily.step]?
    evt.arg.cpz = me.event_daily.stepPrize[me.event_daily.step]

  ret.push(evt)
  return ret
exports.initCampaign = initCampaign

exports.initCalcDungeonBaseRank = (me) ->
  if me.event_daily? and me.event_daily.step < 4
    modifier = [0.8, 1, 1, 1.2]
    return me.event_daily.rank*modifier[me.event_daily.step]

actCampaign = (me, key, config, handler) ->
  initCampaign(me, config)
  return [false, 'NoData'] unless me[key]?

  switch me[key].status
    when 'Ready'
      quest = me[key].quest
      if Array.isArray(quest)
        quest = quest[me[key].step]
      stage = queryTable(TABLE_QUEST, quest).stage ? 1
      if stage? then return me.startDungeon(stage, true, handler)
    when 'Complete'
      if me[key].step < config[key].steps
        prize = me[key].stepPrize[me[key].step]
      else
        if me[key].reward
          prize = me[key].reward
        else if config[key].reward
          prize = config[key].reward
      ret = me.claimPrize(prize)
      me[key].status = 'Claimed'
      ret = ret.concat(initCampaign(me, config))
    when 'Done' then ret = []
    else throw 'WrongCampainStatus'+me[key].status
  if handler
    handler(null, ret)
  else
    return ret

exports.proceedCampaign = actCampaign

exports.events = {
  "event_daily": {
    "flag": "daily",
    "storeType": "player",
    "daily": true,
    "reward": [
      { "prize":{ "type":0, "value":33, "count":1 }, "weight":1 },
      { "prize":{ "type":0, "value":34, "count":1 }, "weight":1 },
      { "prize":{ "type":0, "value":35, "count":1 }, "weight":1 },
      { "prize":{ "type":0, "value":36, "count":1 }, "weight":1 },
      { "prize":{ "type":0, "value":37, "count":1 }, "weight":1 }
    ],
    "steps": 4,
    "quest": [
      128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
      144, 145, 146, 147, 148, 149, 150, 151
    ]
  },
#  "event_energy": {
#    "type": "func",
#    "storeType": "player",
#    "condition": { "cdType": "daily", "time": ["0800", "1200", "1800"], "duration": 60 },
#    "action": {"type": "restoreEnergy"}
#  },
#  "event_goldenSlime": {
#    "type": "randomDungeon",
#    "storeType": "player",
#    "accessCount": 5,
#    "condition": { "cdType": "daily" },
#    "dungeon": [{"weight": 1, "dungeon": 1}]
#  },
#  "globalEvent_classHall": {
#    "type": "dungeon",
#    "completeCount": 1000,
#    "storeType": "global",
#    "condition": { "cdType": "daily" },
#    "action": { "type": "setGlobalFlag", "key": "classHall", "value": true}
#  }
}

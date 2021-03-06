require('./shop')
moment = require('moment')
{Serializer, registerConstructor} = require './serializer'
{DBWrapper, getMercenaryMember, updateMercenaryMember, addMercenaryMember, getPlayerHero} = require './dbWrapper'
{createUnit, Hero} = require './unit'
{Item, Card} = require './item'
{CommandStream, Environment, DungeonEnvironment, DungeonCommandStream} = require('./commandStream')
{Dungeon} = require './dungeon'
{Bag, CardStack} = require('./container')
{diffDate, currentTime} = require ('./helper')
helperLib = require ('./helper')

dbLib = require('./db')
async = require('async')

class Player extends DBWrapper
  constructor: (name) ->
    super
    @attrSave('name', name) if name?
    @attrSave('questTableVersion', -1)
    @attrSave('stageTableVersion', -1)

    @attrSave('inventory', Bag(InitialBagSize))
    @attrSave('gold', 0)
    @attrSave('diamond', 0)
    @attrSave('equipment', {})
    @attrSave('inventoryVersion', 0)
    @versionControl('inventoryVersion', ['gold', 'diamond', 'inventory', 'equipment'])

    @attrSave('heroBase', {})
    @versionControl('heroVersion', ['hero', 'heroBase'])

    @attrSave('stage', [])
    @attrSave('stageVersion', 0)
    @versionControl('stageVersion', 'stage')

    @attrSave('quests', {})
    @attrSave('questsVersion', 0)
    @versionControl('questVersion', 'quests')

    now = new Date()
    @attrSave('energy', ENERGY_MAX)
    @attrSave('energyTime', now.valueOf())
    @versionControl('energyVersion', ['energy', 'energyTime'])

    @attrSave('flags', {})
    @attrSave('mercenary', [])
    @attrSave('dungeonData', null)
    @attrSave('runtimeID', -1)
    @attrSave('rmb', 0)
    @attrSave('spendedDiamond', 0)
    @attrSave('tutorialStage', 0)
    @attrSave('purchasedCount', {})
    @attrSave('lastLogin', currentTime())
    @attrSave('creationDate', now.valueOf())
    @versionControl('dummyVersion', ['isNewPlayer', 'loginStreak', 'accountID'])

  logout: (reason) ->
    if @socket then @socket.encoder.writeObject({NTF: Event_ExpiredPID, err: reason})

  onReconnect: (socket) ->
    @fetchMessage(wrapCallback(this, (err, newMessage) ->
      socket.encoder.writeObject(newMessage) if socket?),
      true
    )

  logError: (action, msg) -> @log(action, msg, 'error')

  log: (action, msg, type) ->
    if not msg? then msg = {}
    msg.name = @name
    msg.action = action
    if type and type is 'error'
      logError(msg)
    else
      logUser(msg)

  onDisconnect: () -> delete @messages

  getType: () -> 'player'


  submitCampaign: (campaign, handler) ->
    event = this[campaign]
    if event?
      helperLib.proceedCampaign(@, campaign, helperLib.events, handler)
      @log('submitCampaign', {event: campaign, data: event})
    else
      @logError('submitCampaign', {reason: 'NoEventData', event: campaign})

  syncEvent: () -> return helperLib.initCampaign(@, helperLib.events)

  onLogin: () ->
    @attrSave('loginStreak', {count: 0}) unless @loginStreak?
    if diffDate(@lastLogin) > 0 then @purchasedCount = {}
    @lastLogin = currentTime()
    if diffDate(@creationDate) > 0 then @tutorialStage = 1000 #TODO

    if not @infiniteTimer or not moment().isSame(@infiniteTimer, 'week')
      @attrSave('infiniteTimer', currentTime())
      for s in @stage when s and s.level?
        s.level = 0

    flag = true
    if @loginStreak.date
      dis = diffDate(@loginStreak.date)
      if dis is 0
        flag = false
      else if dis > 1
        @loginStreak.count = 0
    else
      @loginStreak.count = 0

    @log('onLogin', {loginStreak: @loginStreak, date: @lastLogin})
    @onCampaign('RMB')

    ret = [{NTF:Event_CampaignLoginStreak, day: @loginStreak.count, claim: flag}]
    #ret = ret.concat(helperLib.initCampaign(@, helperLib.events))
    return ret

  claimLoginReward: () ->
    if @loginStreak.date
      dis = diffDate(@loginStreak.date)
      if dis is 0
        @logError('claimLoginReward', {prev: @loginStreak.date, today: currentTime()})
        return {ret: RET_Unknown}
    @loginStreak.date = currentTime(true).valueOf()
    @log('claimLoginReward', {loginStreak: @loginStreak.count, date: currentTime()})

    reward = queryTable(TABLE_CAMPAIGN, 'LoginStreak', @abIndex).level[@loginStreak.count].award
    ret = @claimPrize(reward)
    @loginStreak.count += 1
    # TODO: 这个会导致重新登录之后玩家今日奖励变第一天
    @loginStreak.count = 0 if @loginStreak.count >= queryTable(TABLE_CAMPAIGN, 'LoginStreak').level.length
 
    return {ret: RET_OK, res: ret}

  onMessage: (msg) ->
    switch msg.action
      when 'RemovedFromFriendList'
        @removeFriend(msg.name)
        @updateFriendInfo(wrapCallback(this, (err, ret) ->
          if @socket? then @socket.encoder.writeObject(ret))
        )

  initialize: () ->
    dbLib.subscribe(PlayerChannelPrefix+this.name, wrapCallback(this, (msg) =>
      return false unless @socket?
      if msg is 'New Message'
        @fetchMessage(wrapCallback(this, (err, newMessage) ->
          @socket.encoder.writeObject(newMessage))
        )
      else if msg is 'New Friend'
        @updateFriendInfo(wrapCallback(this, (err, ret) ->
          @socket.encoder.writeObject(ret))
        )
      else
        try
          msg = JSON.parse(msg)
          @onMessage(msg)
        catch err
          logError({type: 'Subscribe', err: err, msg: msg})
    ))


    if @isNewPlayer
      @isNewPlayer = false

    @inventory.validate()

    if @hero?
      @updateMercenaryInfo()

    if @questTableVersion isnt queryTable(TABLE_VERSION, 'quest')
      @updateQuestStatus()
      @questTableVersion = queryTable(TABLE_VERSION, 'quest')

    if @stageTableVersion isnt queryTable(TABLE_VERSION, 'stage')
      @updateStageStatus()
      @stageTableVersion = queryTable(TABLE_VERSION, 'stage')
    @loadDungeon()

  handlePayment: (payment, handle) ->
    @log('handlePayment', {payment: payment})
    switch payment.paymentType
      when 'AppStore' then throw 'AppStore Payment'
      when 'PP25', 'ND91'
        myReceipt = payment.receipt
        async.waterfall([
          (cb) ->
            dbWrapper.getReceipt(myReceipt, (err, receipt) ->
              if receipt? and receipt.state isnt  RECEIPT_STATE_DELIVERED then cb(Error(RET_Issue37)) else cb(null, receipt)
            )
          ,
          (receipt, cb) =>
            productList = queryTable(TABLE_CONFIG, 'Product_List')
            rec = unwrapReceipt(myReceipt)
            cfg = productList[rec.productID]
            ret = [{ NTF: Event_InventoryUpdateItem, arg: { dim : @addDiamond(cfg.diamond) }}]
            @rmb += cfg.rmb
            @onCampaign('RMB', cfg.rmb)
            @log('charge', {rmb: cfg.rmb, diamond: cfg.diamond, tunnel: 'PP', action: 'charge', product: rec.pid, receipt : myReceipt })
            ret.push({NTF: Event_PlayerInfo, arg: { rmb: @rmb }})
            ret.push({NTF: Event_RoleUpdate, arg: { act: {vip: @vipLevel()}}})
            postPaymentInfo(@createHero().level, myReceipt, payment.paymentType)
            dbWrapper.updateReceipt(myReceipt, RECEIPT_STATE_CLAIMED, (err) -> cb(err, ret))
            @saveDB()
        ], (error, result) =>
          if error
            logError({name: @name, receipt: myReceipt, type: 'handlePayment', error: error, result: result})
            handle(null, [])
          else
            handle(null, result)
        )

  updateStageStatus: () ->
    ret = []
    for s in updateStageStatus(@stage, @, @abIndex)
      ret = ret.concat(@changeStage(s, STAGE_STATE_ACTIVE))
    return ret

  updateQuestStatus: () ->
    ( @acceptQuest(q) for q in updateQuestStatus(@quests, @, @abIndex) )

  loadDungeon: () ->
    if @dungeonData?
      @dungeon = new Dungeon(@dungeonData)
      @dungeon.initialize()

  releaseDungeon: () ->
    delete @dungeon
    @dungeonData = null
    dbLib.removeDungeon(@name)

  getPurchasedCount: (id) -> return @purchasedCount[id] ? 0

  addPurchasedCount: (id, count) ->
    @purchasedCount[id] = 0 unless @purchasedCount[id]?
    @purchasedCount[id] += count

  createHero: (heroData) ->
    if heroData?
      return null if @heroBase[heroData.class]?
      heroData.xp = 0
      heroData.equipment = []
      @heroBase[heroData.class] = heroData
      @switchHero(heroData.class)
      return @createHero()
    else if @hero
      bag = @inventory
      equip = []
      equip.push({ cid: bag.get(e).classId, eh: bag.get(e).enhancement }) for i, e of @equipment when bag.get(e)?
      @hero.equipment = equip
      @hero.vip = @vipLevel()
      return new Hero(@hero)
    else
      throw 'NoHero'

  switchHero: (hClass) ->
    return false unless @heroBase[hClass]?

    if @hero?
      @heroBase[@hero.class] = @hero
      @hero = @heroBase[hClass]
    else
      @attrSave('hero', @heroBase[hClass])

    @hero.equipment = {}
    @hero.vip = @vipLevel()

  addMoney: (type, point) ->
    return this[type] unless point
    return false if point + this[type] < 0
    this[type] += point
    @costedDiamond += point if type is 'diamond'
    @inventoryVersion++
    return this[type]

  addDiamond: (point) -> @addMoney('diamond', point)

  addGold: (point) -> @addMoney('gold', point)

  addHeroExp: (point) ->
    if point
      prevLevel = @createHero().level
      @hero.xp += point
      currentLevel = @createHero().level
      @onEvent('experience')
      if prevLevel isnt currentLevel
        if currentLevel is 10 then dbLib.broadcastEvent(BROADCAST_PLAYER_LEVEL, {who: @name, what: @hero.class})
        @onEvent('level')
        @log('levelChange', {prevLevel: prevLevel, newLevel: currentLevel})

    return @hero.xp

  costEnergy: (point) ->
    now = new Date()

    if @energyTime? and @energy < @energyLimit()
      incTime = now - @energyTime
      incPoint = incTime / ENERGY_RATE
      @energy += incPoint
      @energy = @energyLimit() if @energy > @energyLimit()

    @energyTime = now.valueOf()

    if point
      if @energy < point then return false
      @energy -= point

    return true

  saveDB: (handler) -> @save(handler)

  stageIsUnlockable: (stage) ->
    stageConfig = queryTable(TABLE_STAGE, stage, @abIndex)
    if stageConfig.event
      return @[stageConfig.event]? and @[stageConfig.event].status is 'Ready'
    return @stage[stage] and @stage[stage].state != STAGE_STATE_INACTIVE

  changeStage: (stage, state) ->
    stg = queryTable(TABLE_STAGE, stage)
    @stageVersion++
    if stg
      chapter = stg.chapter
      @stage[stage] = {} unless @stage[stage]

      flag = false
      arg = {chp: chapter, stg:stage, sta:state}

      if stg.isInfinite
        @stage[stage].level = 0 unless @stage[stage].level?
        if state is STAGE_STATE_PASSED
          @stage[stage].level += 1
          if @stage[stage].level%5 is 0
            dbLib.broadcastEvent(BROADCAST_INFINITE_LEVEL, {who: @name, where: stage, many: @stage[stage].level})

        arg.lvl = @stage[stage].level
        flag = true

      operation = 'unlock'
      operation = 'complete' if state is STAGE_STATE_PASSED

      ret = []
      if @stage[stage].state isnt state
        if stg.tutorial? and state is STAGE_STATE_PASSED
          @tutorialStage = stg.tutorial
          ret.push({NTF: Event_TutorialInfo, arg: { tut: @tutorialStage }})
        @stage[stage].state = state
        flag = true

      if flag then ret.push({NTF: Event_UpdateStageInfo, arg: {syn: @stageVersion, stg:[arg]}})

      @log('stage', { operation: operation, stage: stage })
      return ret

  dungeonAction: (action) ->
    return [{NTF: Event_Fail, arg: 'Dungeon not exist.'}] unless @dungeon?
    ret = [].concat(@dungeon.doAction(action))
    ret = ret.concat(@claimDungeonAward(@dungeon.reward)) if @dungeon.reward?
    return ret

  startDungeon: (stage, startInfoOnly, handler) ->
    stageConfig = queryTable(TABLE_STAGE, stage, @abIndex)
    dungeonConfig = queryTable(TABLE_DUNGEON, stageConfig.dungeon, @abIndex)
    unless stageConfig? and dungeonConfig?
      @logError('startDungeon', {reason: 'InvalidStageConfig', stage: stage, stageConfig: stageConfig?, dungeonConfig: dungeonConfig?})
      return handler(null, RET_ServerError)
    async.waterfall([
      (cb) => if @dungeonData then cb('OK') else cb(),
      (cb) => if @stageIsUnlockable(stage) then cb() else cb(RET_StageIsLocked),
      (cb) => if @costEnergy(stageConfig.cost) then cb() else cb(RET_NotEnoughEnergy),
      (cb) => @requireMercenary((team) => cb(null, team)),
      (mercenary, cb) =>
        teamCount = stageConfig.team ? 3
        if @stage[stage]? and @stage[stage].level?
          level = @stage[stage].level
          if level%10 is 0 then teamCount = 1
          else if level%5 is 0 then teamCount = 2

        team = [@createHero()]

        if stageConfig.teammate? then team = team.concat(stageConfig.teammate.map( (hd) -> new Hero(hd) ))
        if teamCount > team.length
          if mercenary.length >= teamCount-team.length
            team = team.concat(mercenary.splice(0, teamCount-team.length))
            @mercenary.splice(0, teamCount-team.length)
          else
            @costEnergy(-stageConfig.cost)
            return cb(RET_NeedTeammate)
        cb(null, team, level)
      ,
      (team, level, cb) =>
        blueStar = team.reduce(wrapCallback(this, (r, l) ->
          if not l.leftBlueStar? then return r
          if l.leftBlueStar >= 0
            return @getBlueStarCost()+r
          else
            dbLib.incrBluestarBy(l.name, -l.leftBlueStar, () -> {})
            return @getBlueStarCost()+r+l.leftBlueStar
        ), 0)
        cb(null, team, level, blueStar)
      ,
      (team, level, blueStar, cb) =>
        quest = {}
        for qid, qst of @quests when not qst.complete
          quest[qid] = qst
        cb(null, team, level, blueStar, quest)
      ,
      (team, level, blueStar, quest, cb) =>
        @dungeonData = {
          stage: stage,
          initialQuests: quest,
          infiniteLevel: level,
          blueStar: blueStar,
          abIndex: @abIndex,
          team: team.map(getBasicInfo)
        }
        @dungeonData.randSeed = rand()
        @dungeonData.baseRank = helperLib.initCalcDungeonBaseRank(@) if stageConfig.event is 'event_daily'
        cb('OK')
      ], (err) =>
        @loadDungeon()
        @log('startDungeon', {dungeonData: @dungeonData, err: err})
        if err isnt 'OK'
          ret = err
          err = new Error(err)
        else if @dungeon?
          ret = if startInfoOnly then @dungeon.getInitialData() else @dungeonAction({CMD:RPC_GameStartDungeon})
        else
          @logError('startDungeon', { reason: 'NoDungeon', err: err, data: @dungeonData, dungeon: @dungeon })
          @releaseDungeon()
          err = new Error(RET_Unknown)
          ret = RET_Unknown
        handler(err, ret) if handler?
      )

  acceptQuest: (qid) ->
    return [] if @quests[qid]
    quest = queryTable(TABLE_QUEST, qid, @abIndex)
    @quests[qid] = {counters: (0 for i in quest.objects)}
    @questsVersion++
    @onEvent('gold')
    @onEvent('diamond')
    @onEvent('item')

    return packQuestEvent(@quests, qid, @questVersion)

  claimPrize: (prize, allOrFail = true) ->
    return [] unless prize?
    prize = [prize] unless Array.isArray(prize)
    itemPrize = []
    otherPrize = []
    for p in prize
      if p.type is PRIZETYPE_ITEM
        if p.count > 0 then itemPrize.push(p)
      else
        otherPrize.push(p)
    if itemPrize.length > 1
      itemPrize = [{
        type: PRIZETYPE_ITEM,
        value: itemPrize.map((e) -> return {item: e.value, count: e.count}),
        count: 0
      }]
    prize = itemPrize.concat(otherPrize)

    ret = []

    for p in prize when p?
      switch p.type
        when PRIZETYPE_ITEM
          ret = @aquireItem(p.value, p.count, allOrFail)
          return false unless ret and ret.length > 0
        when PRIZETYPE_GOLD then ret.push({NTF: Event_InventoryUpdateItem, arg: {syn: @inventoryVersion, god: @addGold(p.count)}})
        when PRIZETYPE_DIAMOND then ret.push({NTF: Event_InventoryUpdateItem, arg: {syn: @inventoryVersion, dim: @addDiamond(p.count)}})
        when PRIZETYPE_EXP then ret.push({NTF: Event_RoleUpdate, arg: {syn: @heroVersion, act: {exp: @addHeroExp(p.count)}}})
        when PRIZETYPE_WXP
          continue unless p.count
          equipUpdate = []
          for i, k of @equipment
            e = @getItemAt(k)
            unless e?
              logError({action: 'claimPrize', reason: 'equipmentNotExist', name: @name, equipSlot: k, index: i})
              delete @equipment[k]
              continue
            e.xp = e.xp+p.count
            equipUpdate.push({sid: k, xp: e.xp})
          if equipUpdate.length > 0
            ret.push({NTF: Event_InventoryUpdateItem, arg: {syn: @inventoryVersion, itm: equipUpdate}})
        when PRIZETYPE_FUNCTION
          switch p.func
            when "setFlag"
              @flags[p.flag] = p.value
              ret = ret.concat(@syncFlags(true)).concat(@syncEvent())
    return ret

  isQuestAchieved: (qid) ->
    return false unless @quests[qid]?
    quest = queryTable(TABLE_QUEST, qid, @abIndex)
    for i, c of @quests[qid].counters
      return false if quest.objects[i].count > c
    return true

  claimQuest: (qid) ->
    quest = queryTable(TABLE_QUEST, qid, @abIndex)
    ret = []
    return RET_Unknown unless quest? and @quests[qid]? and not @quests[qid].complete
    @checkQuestStatues(qid)
    return RET_Unknown unless @isQuestAchieved(qid)

    prize = @claimPrize(quest.prize.filter((e) => isClassMatch(@hero.class, e.classLimit)))
    if not prize or prize.length is 0 then return RET_InventoryFull
    ret = ret.concat(prize)

    @questsVersion++
    for obj in quest.objects when obj.consume
      switch obj.type
        when QUEST_TYPE_GOLD then ret = ret.concat({NTF: Event_InventoryUpdateItem, arg: {syn:@inventoryVersion, god: @addGold(-obj.count)}})
        when QUEST_TYPE_DIAMOND then ret = ret.concat({NTF: Event_InventoryUpdateItem, arg: {syn:@inventoryVersion, dim: @addDiamond(-obj.count)}})
        when QUEST_TYPE_ITEM then ret = ret.concat(this.removeItem(obj.value, obj.count))

    @log('claimQuest', { id: qid })
    @quests[qid] = {complete: true}
    return ret.concat(@updateQuestStatus())

  checkQuestStatues: (qid) ->
    quest = queryTable(TABLE_QUEST, qid, @abIndex)
    return false unless @quests[qid]? and quest

    for i, objective of quest.objects
      switch objective.type
        when QUEST_TYPE_GOLD then @quests[qid].counters[i] = @gold
        when QUEST_TYPE_DIAMOND then @quests[qid].counters[i] = @diamond
        when QUEST_TYPE_ITEM then @quests[qid].counters[i] = @inventory.filter((e) -> e.id is objective.collect).reduce( ((r,l) -> r+l.count), 0 )
        when QUEST_TYPE_LEVEL then @quests[qid].counters[i] = @createHero().level
        when QUEST_TYPE_POWER then @quests[qid].counters[i] = @createHero().calculatePower()
      if @quests[qid].counters[i] > objective.count then @quests[qid].counters[i] = objective.count

  onEvent: (eventID) ->
    switch eventID
      when 'gold', 'diamond', 'item' then
      when 'level'
        @onEvent('power')
        @onCampaign('Level')
      #when 'experience',
      when 'Equipment' then @onEvent('power')
      when 'power' then @updateMercenaryInfo()

  queryItemSlot: (item) -> @inventory.queryItemSlot(item)

  getItemAt: (slot) -> @inventory.get(slot)

  useItem: (slot)->
    item = @getItemAt(slot)
    myClass = @hero.class
    return { ret: RET_ItemNotExist } unless item?
    return { ret: RET_RoleClassNotMatch } unless isClassMatch(myClass, item.classLimit)
    @log('useItem', { slot: slot, id: item.id })

    @inventoryVersion++
    switch item.category
      when ITEM_USE
        switch item.subcategory
          when ItemUse_ItemPack
            prize = @claimPrize(item.prize)
            return { ret: RET_InventoryFull } unless prize
            ret = @removeItem(null, 1, slot)
            return { ret: RET_OK, ntf: ret.concat(prize) }
          when ItemUse_TreasureChest
            return { ret: RET_NoKey } if item.dropKey? and not @haveItem(item.dropKey)
            dropData = queryTable(TABLE_DROP, item.dropId, @abIndex)
            unless dropData? and dropData.dropList
              logError({'action': 'useItem', type: 'TreasureChest', reason: 'invalidDropData', id: item.id})
              return { ret: RET_Unknown }
            e = selectElementFromWeightArray(dropData.dropList, Math.random())
            prize = @claimPrize(e.drop)
            return { ret: RET_InventoryFull } unless prize
            @log('openTreasureChest', {type: 'TreasureChest', id: item.id, prize: prize, drop: e.drop})
            ret = prize.concat(@removeItem(null, 1, slot))
            ret = ret.concat(this.removeItemById(item.dropKey, 1, true)) if item.dropKey?
            if e.drop.type is PRIZETYPE_ITEM and queryTable(TABLE_ITEM, e.drop.value, @abIndex)?.quality >= 2
              dbLib.broadcastEvent(BROADCAST_TREASURE_CHEST, {who: @name, src: item.id, out: e.drop.value})
            return {prize: [e.drop], res: ret}
          when ItemUse_Function
            ret = @removeItem(null, 1, slot)
            switch item.function
              when 'recoverEnergy'
                this.costEnergy(-item.argument)
                ret = ret.concat(this.syncEnergy())
            return { ret: RET_OK, ntf: ret }
      when ITEM_EQUIPMENT
        return { ret: RET_RoleLevelNotMatch } if item.rank? and this.createHero().level < item.rank
        ret = {NTF: Event_InventoryUpdateItem, arg: {syn:this.inventoryVersion, itm: []}}
        equip = this.equipment[item.subcategory]
        tmp = {sid: slot, sta: 0}
        if equip is slot
          delete this.equipment[item.subcategory]
        else
          if equip? then ret.arg.itm.push({sid: equip, sta: 0})
          this.equipment[item.subcategory] = slot
          tmp.sta = 1
        ret.arg.itm.push(tmp)
        delete ret.arg.itm if ret.arg.itm.length < 1

        this.onEvent('Equipment')
        return { ret: RET_OK, ntf: ret }

    logError({action: 'useItem', reason: 'unknow', catogory: item.category, subcategory: item.subcategory, id: item.id})
    return {ret: RET_Unknown}

  doAction: (routine) ->
    cmd = new playerCommandStream(routine, this)
    cmd.process()
    return cmd.translate()

  aquireItem: (item, count, allOrFail) ->
    @inventoryVersion++
    @doAction({id: 'AquireItem', item: item, count: count, allorfail: allOrFail})

  removeItemById: (id, count, allorfail) ->
    @inventoryVersion++
    @doAction({id: 'RemoveItem', item: id, count: count, allorfail: allorfail})
  removeItem: (item, count, slot) ->
    @inventoryVersion++
    @doAction({id: 'RemoveItem', item: item, count: count, slot: slot})

  extendInventory: (delta) -> @inventory.size(delta)

  transformGem: (count) ->
    gem7 = 0
    goldCost = count*50
    return { ret: RET_NotEnoughGold } unless goldCost <= @gold
    retRM = @inventory.removeById(gem7, count, true)
    return { ret: RET_NoEnhanceStone } unless retRM
    @addGold(-goldCost)
    gems = {}
    gemIndex = queryTable(TABLE_CONFIG, 'Global_Enhancement_GEM_Index', @abIndex)
    prize = []
    for i in [1..Math.floor(count*0.5)]
      r = rand() % gemIndex.length
      unless gems[r]?
        gems[r] = { type : PRIZETYPE_ITEM, value: gemIndex[r], count: 0}
        prize.push(gems[r])
      gems[r].count++

    retPrize = @claimPrize(prize)
    if retPrize
      ret = @doAction({id: 'ItemChange', ret: retRM, version: @inventoryVersion})
      ret = ret.concat(retPrize)
      ret = ret.concat({NTF: Event_InventoryUpdateItem, arg:{syn: @inventoryVersion, god: @gold }})
      return { out: prize, res: ret }
    else
      @inventory.reverseOpration(retRM)
      return { ret: RET_InventoryFull }

  craftItem: (slot) ->
    recipe = @getItemAt(slot)
    return { ret: RET_NeedReceipt } unless recipe.category is ITEM_RECIPE
    return { ret: RET_NotEnoughGold } if @gold < recipe.recipeCost
    retRM = @inventory.removeById(recipe.recipeIngredient, true)
    return { ret: RET_InsufficientIngredient } unless retRM
    ret = @removeItem(null, 1, slot)
    ret = ret.concat(@doAction({id: 'ItemChange', ret: retRM, version: this.inventoryVersion}))
    @addGold(-recipe.recipeCost)
    newItem = new Item(recipe.recipeTarget)
    ret = ret.concat(@aquireItem(newItem))
    ret = ret.concat({NTF: Event_InventoryUpdateItem, arg:{syn: @inventoryVersion, god: @gold }})
    @log('craftItem', { slot: slot, id: recipe.id })

    if newItem.rank >= 8
      dbLib.broadcastEvent(BROADCAST_CRAFT, {who: @name, what: newItem.id})
    return { out: { type: PRIZETYPE_ITEM, value: newItem.id, count: 1}, res: ret }

  levelUpItem: (slot) ->
    item = @getItemAt(slot)
    return { ret: RET_ItemNotExist } unless item?
    return { ret: RET_EquipCantUpgrade } unless item.upgradeTarget? and @createHero().level > item.rank
    upConfig = queryTable(TABLE_UPGRADE, item.rank, @abIndex)
    return { ret: RET_EquipCantUpgrade } unless upConfig
    exp = item.upgradeXp ? upConfig.xp
    cost = item.upgradeCost ? upConfig.cost
    return { ret: RET_EquipCantUpgrade } unless exp? and cost?
    return { ret: RET_InsufficientEquipXp } if item.xp < exp
    return { ret: RET_NotEnoughGold } if this.gold < cost

    delete @equipment[k] for k, s of @equipment when s is slot

    @inventoryVersion++
    this.addGold(-cost)
    ret = this.removeItem(null, 1, slot)
    newItem = new Item(item.upgradeTarget)
    newItem.enhancement = item.enhancement
    ret = ret.concat(this.aquireItem(newItem))
    ret = ret.concat(this.useItem(this.queryItemSlot(newItem)).ntf)
    eh = newItem.enhancement.map((e) -> {id:e.id, lv:e.level})
    ret = ret.concat({NTF: Event_InventoryUpdateItem, arg:{syn:this.inventoryVersion, god:this.gold, itm:[{sid: this.queryItemSlot(newItem), stc: 1, eh:eh}]}})
  
    @log('levelUpItem', { slot: slot, id: item.id, level: item.rank })
  
    if newItem.rank >= 8
      dbLib.broadcastEvent(BROADCAST_ITEM_LEVEL, {who: @name, what: item.id, many: newItem.rank})

    @onEvent('Equipment')
    return { out: {cid: newItem.id, sid: @queryItemSlot(newItem), stc: 1, sta: 1, eh: eh, xp: newItem.xp}, res: ret }

  enhanceItem: (itemSlot, gemSlot) ->
    equip = @getItemAt(itemSlot)
    gem = @getItemAt(gemSlot)
    return { ret: RET_ItemNotExist } unless equip and gem
    return { ret: RET_EquipCantUpgrade } unless equip.category is ITEM_EQUIPMENT and equip.subcategory <= EquipSlot_Neck
    return { ret: RET_NoEnhanceStone } unless gem.category is ITEM_GEM
    maxLevel = -1
    minLevel = 1000000
    maxIndex = -1
    minIndex = 0
    for i, enhance of equip.enhancement
      if enhance.level > maxLevel
        maxLevel = enhance.level
        maxIndex = i
      if enhance.level < minLevel
        minLevel = enhance.level
        minIndex = i

    @inventoryVersion++
    level = 0
    enhanceID = -1
    maxLevel++
    cost = maxLevel*2
    if cost < 1 then cost = 1
    gold = cost*200
    return { ret: RET_NotEnoughGold } if @addGold(-gold) is false
    retRM = @inventory.remove(gem.id, cost, gemSlot, true)
    if not retRM
      @addGold(gold)
      return { ret: RET_NoEnhanceStone }

    if gem.subcategory is ENHANCE_VOID
      if maxIndex is -1 then return { ret: RET_CantUseVoidStone }
      leftEnhancement = [RES_ATTACK, RES_HEALTH, RES_SPEED, RES_CRITICAL, RES_STRONG, RES_ACCURACY, RES_REACTIVITY]
      equip.enhancement.forEach( (e) -> leftEnhancement = leftEnhancement.filter( (l) -> l isnt e.id ) )
      enhance = leftEnhancement[ rand()%leftEnhancement.length ]
      equip.enhancement[maxIndex].id = enhance
      equip.enhancement.push(equip.enhancement.shift())
    else
      myEnhancements = equip.enhancement.map((e) -> e.id )
      enhance7 = [RES_ATTACK, RES_HEALTH, RES_SPEED, RES_CRITICAL, RES_STRONG, RES_ACCURACY, RES_REACTIVITY]
      #enhance7 = enhance7.filter( (e) -> myEnhancements.indexOf(e) == -1 )
      enhance7 = enhance7[rand()%enhance7.length]
      enhanceTable = [enhance7, 0, 0, RES_ATTACK, RES_HEALTH, RES_SPEED, RES_CRITICAL, RES_STRONG, RES_ACCURACY, RES_REACTIVITY]
      enhanceID = enhanceTable[gem.subcategory]
      index = i for i, enhance of equip.enhancement when enhance.id is enhanceID
      if index < equip.enhancement.length
        level = equip.enhancement[index].level+1
      else if equip.enhancement.length < ENHANCE_LIMIT
        index = equip.enhancement.length
      else
        index = minIndex

      rate = queryTable(TABLE_CONFIG, "Enhance_Rate", @abIndex)[level]

      if level >= equip.rank
        if gem.subcategory isnt ENHANCE_SEVEN
          return { ret: RET_ExceedMaxEnhanceLevel }
        else
          rate = -1

      if Math.random() < rate
        equip.enhancement[index] = { id: enhanceID, level: level }
        result = 'Success'
      else
        result = 'Fail'
  
    ret = [{NTF: Event_InventoryUpdateItem, arg: {syn:this.inventoryVersion, 'god': @gold}}]
    ret = ret.concat(@doAction({id: 'ItemChange', ret: retRM, version: this.inventoryVersion}))
    @log('enhanceItem', { itemId: equip.id, gemId: gem.subcategory, result: result, enhance: enhanceID, level: level, itemSlot: itemSlot, gemSlot: gemSlot })
  
    return { ret: RET_EnhanceFailed, ntf: ret} if result is 'Fail'

    @onEvent('Equipment')

    if level >= 5
      dbLib.broadcastEvent(BROADCAST_ENHANCE, {who: @name, what: equip.id, many: level})
  
    eh = equip.enhancement.map((e) -> {id:e.id, lv:e.level})
    ret = ret.concat({NTF: Event_InventoryUpdateItem, arg: {syn:this.inventoryVersion, itm:[{sid: itemSlot, eh:eh}]}})
    return { out: {cid: equip.id, sid: itemSlot, stc: 1, eh: eh, xp: equip.xp}, res: ret }

  sellItem: (slot) ->
    item = @getItemAt(slot)
    return { ret: RET_Unknown } for k, s of @equipment when s is slot

    if item?.sellprice
      @addGold(item.sellprice*item.count)
      ret = this.removeItem(null, null, slot)
  
      @log('sellItem', { itemId: item.id, price: item.sellprice, count: item.count, slot: slot })
      return { ret: RET_OK, ntf: [{ NTF: Event_InventoryUpdateItem, arg: {syn:this.inventoryVersion, 'god': this.gold} }].concat(ret)}
    else
      return { ret: RET_Unknown }

  haveItem: (itemID) ->
    itemConfig = queryTable(TABLE_ITEM, itemID, @abIndex)
    return false unless itemConfig?

    matchedItems = this.inventory.filter((item) -> item? and item.id is itemID)
    if matchedItems.length > 0
      return true
    else if itemConfig.upgradeTarget
      return this.haveItem(itemConfig.upgradeTarget)
    else
      return false

  generateDungeonAward: (reward) ->
    items = []
  
    if reward.result is DUNGEON_RESULT_DONE then return []
    if reward.result is DUNGEON_RESULT_WIN
      dbLib.incrBluestarBy(this.name, 1)
      items = []
      if reward.prize
        items = reward.prize
          .filter((p) -> Math.random() < p.rate )
          .map(wrapCallback(this, (g) ->
            dropTable = queryTable(TABLE_CONFIG, "Global_Item_Drop_Table", @abIndex) ? []
            g.items =  g.items.concat(dropTable).filter( (i) =>
              itemConfig = queryTable(TABLE_ITEM, i.item, @abIndex)
              if not itemConfig then return false
              if itemConfig.singleton then return !@haveItem(i.item)
              return true
            )
            return g
          ))
          .map((g) ->
            e = selectElementFromWeightArray(g.items, Math.random())
            # TODO: quick fix
            if e
              return {type:PRIZETYPE_ITEM, value:e.item, count:1}
            else
              logError({type: 'QuickFix', group: g, reward: reward})
              return {type:PRIZETYPE_ITEM, value:g[0], count:1}
          )
  
    if reward.infinityPrize and reward.result is DUNGEON_RESULT_WIN
      if reward.infinityPrize.type is PRIZETYPE_GOLD
        reward.gold += reward.infinityPrize.count
      else
        items.push(reward.infinityPrize)
  
    reward.gold += reward.gold*@goldAdjust()
    reward.exp += reward.exp*@expAdjust()
    reward.wxp += reward.wxp*@wxpAdjust()
    reward.gold = Math.ceil(reward.gold)
    reward.exp = Math.ceil(reward.exp)
    reward.wxp = Math.ceil(reward.wxp)
    reward.item = items
  
    return [
      {type:PRIZETYPE_EXP, count : reward.exp},
      {type:PRIZETYPE_GOLD, count : reward.gold},
      {type:PRIZETYPE_WXP, count : reward.wxp}
    ].concat(items)

  claimDungeonAward: (reward) ->
    unless reward? and @dungeon?
      player.saveDB(() -> player.releaseDungeon())
      return []

    ret = []
    if reward.reviveCount > 0
      ret = @inventory.removeById(ItemId_RevivePotion, reward.reviveCount, true)
      if not ret or ret.length is 0
        return { NTF: Event_DungeonReward, arg : { prize : prize, res : 0 } }
      ret = this.doAction({id: 'ItemChange', ret: ret, version: this.inventoryVersion})
  
    if reward.quests
      for qid, qst of reward.quests
        continue unless qst?.counters? and @quests[qid]
        quest = queryTable(TABLE_QUEST, qid, @abIndex)
        for k, objective of quest.objects when objective.type is QUEST_TYPE_NPC and qst.counters[k]? and @quests[qid].counters?
          @quests[qid].counters[k] = qst.counters[k]
      @questVersion++
  
    prize = this.generateDungeonAward(reward)
    prize = prize.filter( (e) ->
      if e.count? and e.count is 0 then return false
      return true
    )
    rewardMessage = { NTF : Event_DungeonReward, arg : { res : reward.result } }
    if prize.length > 0 then rewardMessage.arg.prize = prize
  
    ret = ret.concat([rewardMessage])
    if reward.result isnt DUNGEON_RESULT_FAIL then ret = ret.concat(this.completeStage(this.dungeon.stage))
    ret = ret.concat(this.claimPrize(prize, false))
  
    offlineReward = []
    offlineReward.push({type:PRIZETYPE_EXP, count:Math.ceil(TEAMMATE_REWARD_RATIO * reward.exp)}) if reward.exp > 0
    offlineReward.push({type:PRIZETYPE_GOLD, count:Math.ceil(TEAMMATE_REWARD_RATIO * reward.gold)}) if reward.gold > 0
    offlineReward.push({type:PRIZETYPE_WXP, count:Math.ceil(TEAMMATE_REWARD_RATIO * reward.wxp)}) if reward.wxp > 0
    if offlineReward.length > 0
      teammateRewardMessage = { type: MESSAGE_TYPE_SystemReward, src : MESSAGE_REWARD_TYPE_OFFLINE, prize : offlineReward }
      reward.team.forEach((name) -> if name then dbLib.deliverMessage(name, teammateRewardMessage) )
  
    result = 'Lost'
    result = 'Win' if reward.result is DUNGEON_RESULT_WIN

    @log('finishDungeon', { stage : this.dungeon.getInitialData().stage, result : result, reward : prize })
  
    @saveDB(() => @releaseDungeon())
    return ret

  whisper: (name, message, callback) ->
    myName = this.name
    dbLib.deliverMessage(
      name,
      { type: Event_ChatInfo, src: myName, mType: MESSAGETYPE_WHISPER, text: message, timeStamp: (new Date()).valueOf(), vip: @vipLevel(), class: @hero.class, power: @battleForce },
      (err, result) =>
        @log('whisper', { to : name, err : err, text : message })

        if callback then callback(err, result)
      )

  inviteFriend: (name, id, callback) ->
    msg = {type:  MESSAGE_TYPE_FriendApplication, name: this.name}
    async.series([
      (cb) ->
        if id?
          dbLib.getPlayerNameByID(id, (err, theName) ->
            if theName then name = theName
            cb(err)
          )
        else
          cb(null)
      (cb) => if name is @name then cb(new Error(RET_CantInvite)) else cb (null),
      (cb) => if @contactBook? and @contactBook.book.indexOf(name) isnt -1 then cb(new Error(RET_OK)) else cb (null),
      (cb) -> dbLib.playerExistenceCheck(name, cb),
      (cb) -> dbLib.deliverMessage(name, msg, cb),
    ], (err, result) ->
      err = new Error(RET_OK) unless err?
      if callback then callback(err)
    )

  removeFriend: (name) ->
    @log('removeFriend', {tar : name})

    dbLib.removeFriend(this.name, name)
    return RET_OK

  vipOperation: (op) ->
    {level, cfg} = getVip(@rmb)

    switch op
      when 'vipLevel' then return level
      when 'blueStarCost' then return cfg?.blueStarCost ? 0
      when 'goldAdjust' then return cfg?.goldAdjust ? 0
      when 'expAdjust' then return cfg?.expAdjust ? 0
      when 'wxpAdjust' then return cfg?.wxpAdjust ? 0
      when 'energyLimit' then return (cfg?.energyLimit ? 0) + ENERGY_MAX

  vipLevel: () -> @vipOperation('vipLevel')
  getBlueStarCost: () -> @vipOperation('blueStarCost')
  goldAdjust: () -> @vipOperation('goldAdjust')
  expAdjust: () -> @vipOperation('expAdjust')
  wxpAdjust: () -> @vipOperation('wxpAdjust')
  energyLimit: () -> @vipOperation('energyLimit')

  hireFriend: (name, handler) ->
    return false unless handler?
    return handler(RET_Unknown) if this.contactBook.book.indexOf(name) is -1

    myIndex = this.mercenary.reduce((r, e, index) ->
      return index if e.name is name
      return r
    , -1)

    @log('hireFriend', { tar : name })

    if myIndex != -1
      dbLib.incrBluestarBy(name, @getBlueStarCost(), wrapCallback(this,(err, left) ->
        this.mercenary.splice(myIndex, 1)
        this.requireMercenary(handler)
      ))
    else
      dbLib.incrBluestarBy(name, -@getBlueStarCost(), wrapCallback(this,(err, left) ->
        getPlayerHero(name, wrapCallback(this, (err, heroData) ->
          hero = new Hero(heroData)
          hero.isFriend = true
          hero.leftBlueStar = left
          this.mercenary.splice(0, 0, hero)
          this.requireMercenary(handler)
        ))
      ))

  getCampaignState: (campaignName) ->
    if not @campaignState? then @attrSave('campaignState', {})
    if not @campaignState[campaignName]?
      if campaignName is 'Charge'
        @campaignState[campaignName] = {}
      else
        @campaignState[campaignName] = 0
    return @campaignState[campaignName]

  setCampaignState: (campaignName, val) ->
    if not @campaignState? then @attrSave('campaignState', {})
    return @campaignState[campaignName] = val

  getCampaignConfig: (campaignName) ->
    cfg = queryTable(TABLE_CAMPAIGN, campaignName, @abIndex)
    if cfg?
      if cfg.date? and moment(cfg.date).format('YYYYMMDD') - moment().format('YYYYMMDD') < 0 then return { config: null }
      if @getCampaignState(campaignName)? nd @getCampaignState(campaignName) is false then return { config: null }
      if @getCampaignState(campaignName)? and cfg.level? and @getCampaignState(campaignName) >= cfg.level.length then return { config: null }
      if campaignName is 'LevelUp' and cfg.timeLimit*1000 <= moment()- @creationDate then return { config: null }
    else
      return { config: null }
    if cfg.level
      return { config: cfg, level: cfg.level[@getCampaignState(campaignName)] }
    else
      return { config: cfg, level: cfg.objective }

  onCampaign: (state, data) ->
    reward = []
    switch state
      when 'Friend'
        { config, level } = @getCampaignConfig('Friend')
        if config? and level? and @contactBook.book.length >= level.count
          reward.push({cfg: config, lv: level})
          @setCampaignState('Friend', 1)
      when 'RMB'
        { config, level } = @getCampaignConfig('Charge')
        if config? and level?
          rmb = data
          state = @getCampaignState('Charge')
          o = level[rmb]
          if not state[rmb] and o?
            reward.push({cfg: config, lv: o})
            state[rmb] = true
            @setCampaignState('Charge', state)

        { config, level } = @getCampaignConfig('TotalCharge')
        if config? and level? and @rmb >= level.count
          if @getCampaignState('TotalCharge')?
            @setCampaignState('TotalCharge', @getCampaignState('TotalCharge')+1)
          else
            @setCampaignState('TotalCharge', 0)
          reward.push({cfg: config, lv: level})

        { config, level } = @getCampaignConfig('FirstCharge')
        if config? and level?
          rmb = data
          if level[rmb]?
            reward.push({cfg: config, lv: level[rmb]})
            @setCampaignState('FirstCharge', false)
      when 'Level'
        { config, level } = @getCampaignConfig('LevelUp')
        if config? and level? and @createHero().level >= level.count
          if @getCampaignState('LevelUp')?
            @setCampaignState('LevelUp', @getCampaignState('LevelUp')+1)
          else
            @setCampaignState('LevelUp', 1)
          reward.push({cfg: config, lv: level})
      when 'Stage'
        { config, level } = @getCampaignConfig('Stage')
        if config? and level? and data is level.count
          @setCampaignState('Stage', @getCampaignState('Stage')+1)
          reward.push({cfg: config, lv: level})
      when 'BattleForce'
        { config, level } = @getCampaignConfig('BattleForce')
        if config? and level? and @createHero().calculatePower() >= level.count
          @setCampaignState('BattleForce', @getCampaignState('BattleForce')+1)
          reward.push({cfg: config, lv: level})

    for r in reward
      dbLib.deliverMessage(@name, { type: MESSAGE_TYPE_SystemReward, src: MESSAGE_REWARD_TYPE_SYSTEM, prize: r.lv.award, tit: r.cfg.mailTitle, txt: r.cfg.mailBody })

  updateFriendInfo: (handler) ->
    dbLib.getFriendList(@name, wrapCallback(this, (err, book) ->
      @contactBook = book
      @onCampaign('Friend')
      async.map(@contactBook.book,
        (contactor, cb) -> getPlayerHero(contactor, cb),
        (err, result) ->
          ret = {
            NTF: Event_FriendInfo,
            arg: {
              fri: result.map(getBasicInfo),
              cap: book.limit,
              clr: true
            }
          }
          handler(err, ret)
        )
    ))

  operateMessage: (type, id, operation, callback) ->
    me = this
    async.series([
      (cb) =>
        if @messages? and @messages.length > 0
          cb(null)
        else
          @fetchMessage(cb)
      ,
      (cb) =>
        message = me.messages
        @messages = []
        if id?
          message = message.filter((m) -> return m? and m.messageID is id )
          @messages = message.filter((m) -> return m.messageID isnt id )
        if type?
          message = message.filter((m) -> return m? and m.type is type )
          @messages = message.filter((m) -> return m.type isnt type )

        err = null
        cb(err, message)
    ], (err, results) =>
      friendFlag = false
      async.map(results[1], (message, cb) =>
        switch message.type
          when MESSAGE_TYPE_FriendApplication
            if operation is NTFOP_ACCEPT
              dbLib.makeFriends(me.name, message.name, (err) -> cb(err, []))
            else
              cb(null, [])
            friendFlag = true
            @log('operateMessage', { type : 'friend', op : operation })
            dbLib.removeMessage(@name, message.messageID)
          when MESSAGE_TYPE_SystemReward
            ret = @claimPrize(message.prize)
            @log('operateMessage', { type : 'reward', src : message.src, prize : message.prize, ret: ret })
            if ret
              cb(null, ret)
              dbLib.removeMessage(@name, message.messageID)
            else
              cb(RET_InventoryFull, ret)
      , (err, result) =>
        if friendFlag then return @updateFriendInfo(callback)
        if callback then callback(err, result.reduce( ((r, l) -> if l then return r.concat(l) else return r), [] ))
      )
    )

  fetchMessage: (callback, allMessage = false) ->
    myName = this.name
    me = this
    dbLib.fetchMessage(myName, wrapCallback(this, (err, messages) ->
      @messages = [] unless @messages?
      if allMessage
        newMessage = messages
      else
        newMessage = playerMessageFilter(this.messages, messages, myName)
      this.messages = this.messages.concat(newMessage)
      newMessage = newMessage.filter( (m) -> m? )
      async.map(newMessage,
        (msg, cb) ->
          if msg.type == MESSAGE_TYPE_SystemReward
            ret = {
              NTF : Event_SystemReward,
              arg : {
                sid : msg.messageID,
                typ : msg.src,
                prz : msg.prize
              }
            }
            if msg.tit then ret.arg.tit = msg.tit
            if msg.txt then ret.arg.txt = msg.txt
            cb(null, ret)
          else if msg.type == Event_ChatInfo
            dbLib.removeMessage(myName, msg.messageID)
            cb(null, {
              NTF : Event_ChatInfo,
              arg : {
                typ: msg.mType,
                src: msg.src,
                txt: msg.text,
                tms: Math.floor(msg.timeStamp/1000),
                vip: msg.vip,
                cla: msg.class,
                pow: msg.power
              }
            })
          else if msg.type is MESSAGE_TYPE_FriendApplication
            getPlayerHero(msg.name, wrapCallback((err, hero) ->
              cb(err, {
                NTF: Event_FriendApplication,
                arg: {
                  sid: msg.messageID,
                  act: getBasicInfo(hero)
                }
              })
            ))
          else if msg.type is MESSAGE_TYPE_ChargeDiamond
            dbLib.removeMessage(me.name, msg.messageID)
            me.handlePayment(msg, cb)
          else
            cb(err, msg)
        , (err, msg) ->
          ret = []
          for m in msg
            if Array.isArray(m)
              ret = ret.concat(m)
            else
              ret.push(m)
          callback(err, ret) if callback?
      )
    ))

  completeStage: (stage) ->
    thisStage = queryTable(TABLE_STAGE, stage, @abIndex)
    if this.stage[stage] == null || thisStage == null then return []
    ret = this.changeStage(stage,  STAGE_STATE_PASSED)
    @onCampaign('Stage')
    return ret.concat(this.updateStageStatus())

  requireMercenary: (callback) ->
    if !callback then return
    if @mercenary.length >= MERCENARYLISTLEN
      callback(@mercenary.map( (h) -> new Hero(h)))
    else
      #// TODO: range  & count to config
      filtedName = [@name]
      filtedName = filtedName.concat(@mercenary.map((m) -> m.name))
      if @contactBook? then filtedName = filtedName.concat(@contactBook.book)
      getMercenaryMember(filtedName, @battleForce-100, @battleForce+100, 30,
          (err, heroData) =>
            if heroData
              @mercenary.push(heroData)
              @requireMercenary(callback)
            else
              callback(null)
          )

  recycleItem: (slot) ->
    recyclableEnhance = queryTable(TABLE_CONFIG, 'Global_Recyclable_Enhancement', @abIndex)
    recycleConfig = queryTable(TABLE_CONFIG, 'Global_Recycle_Config', @abIndex)
    item = @getItemAt(slot)
    for k, equip of @equipment when equip is slot
      delete @equipment[k]
      break
    ret = []
    try
      if item is null then throw RET_ItemNotExist
      xp = helperLib.calculateTotalItemXP(item) * 0.8
      ret = ret.concat(@removeItem(null, null, slot))
      reward = item.enhancement.map((e) ->
        if recyclableEnhance.indexOf(e.id) != -1
          cfg = recycleConfig[e.level]
          return {
            type : PRIZETYPE_ITEM,
            value : queryTable(TABLE_CONFIG, 'Global_Enhancement_GEM_Index', @abIndex)[e.id],
            count : cfg.minimum + rand() % cfg.delta
          }
        else
          return null
      )
      if queryTable(TABLE_CONFIG, 'Global_Material_ID').length > item.quality
        reward.push({
          type: PRIZETYPE_ITEM,
          value: queryTable(TABLE_CONFIG, 'Global_Material_ID')[item.quality],
          count: 2 + rand() % 2
        })
      reward = reward.filter( (e) -> return e? )
      #reward.push({
      #  type: PRIZETYPE_ITEM,
      #  value: queryTable(TABLE_CONFIG, 'Global_WXP_BOOK'),
      #  count: Math.floor(xp/100)
      #})
      rewardEvt = this.claimPrize(reward)
      ret = ret.concat(rewardEvt)
    catch err
      logError(err)

    return {out: reward, res: ret}

  injectWXP: (slot) ->
    equip = @getItemAt(slot)
    return { ret: RET_ItemNotExist } unless equip
    upgrade = queryTable(TABLE_UPGRADE, equip.rank)
    xpNeeded = upgrade.xp - equip.xp
    bookNeeded = Math.ceil(xpNeeded/100)
    retRM = @inventory.remove(queryTable(TABLE_CONFIG, 'Global_WXP_BOOK'), bookNeeded, null, true)
    if retRM
      equip.xp = upgrade.xp
      ret = @doAction({id: 'ItemChange', ret: retRM, version: this.inventoryVersion})
      return { out: {cid: equip.id, sid: @queryItemSlot(equip), stc: 1, xp: equip.xp}, res: ret }
    else
      return { ret: RET_NoEnhanceStone }


  replaceMercenary: (id, handler) ->
    me = this
    battleForce = this.battleForce
    # TODO: range  & count to config
    filtedName = [@name]
    filtedName = filtedName.concat(me.mercenary.map((m) -> m.name))
    filtedName = filtedName.concat(me.contactBook.book)
    getMercenaryMember(filtedName, battleForce-10, battleForce+200, 30,
      (err, heroData) ->
        if heroData
          me.mercenary.splice(id, 1, heroData)
        else
          heroData = me.mercenary[id]
        handler(heroData)
      )

  updateMercenaryInfo: (isLogin) ->
    newBattleForce = @createHero().calculatePower()

    if newBattleForce != @battleForce
      updateMercenaryMember(@battleForce, newBattleForce, this.name)
      @battleForce = newBattleForce

    if isLogin
      addMercenaryMember(@battleForce, this.name)

  #//////////////////////////// Version Control
  syncFriend: (forceUpdate) ->
    #TODO

  syncBag: (forceUpdate) ->
    bag = this.inventory
    items = bag.container
      .map(wrapCallback(this, (e, index) =>
        return null unless e? and bag.queryItemSlot(e)?
        ret = {sid: bag.queryItemSlot(e), cid: e.id, stc: e.count}

        if e.xp is NaN then console.error({action: 'syncBag', type: 'NaN', name: @name, slot: index, item: e})
        if e.xp is NaN then console.log({action: 'syncBag', type: 'NaN', name: @name, slot: index, item: e})
        if e.xp? then ret.xp = e.xp
        for i, equip of this.equipment when equip is index
          ret.sta = 1

        if e.enhancement
          ret.eh = e.enhancement.map((e) -> {id:e.id, lv:e.level})

        return ret
      )).filter((e) -> e!=null)

    ev = {NTF: Event_InventoryUpdateItem, arg: { cap: bag.limit, dim: this.diamond, god: this.gold, syn: this.inventoryVersion, itm: items } }
    if forceUpdate then ev.arg.clr = true
    return ev

  syncStage: (forceUpdate) ->
    stg = []
    for k, v of this.stage
      if this.stage[k]
        cfg = queryTable(TABLE_STAGE, k, @abIndex)
        if not cfg?
          delete @stage[k]
          continue
        chapter = cfg.chapter
        if this.stage[k].level?
          stg.push({stg:k, sta:this.stage[k].state, chp:chapter, lvl:this.stage[k].level})
        else
          stg.push({stg:k, sta:this.stage[k].state, chp:chapter})

    ev = {NTF : Event_UpdateStageInfo, arg: {syn:this.stageVersion, stg:stg}}
    if forceUpdate then ev.arg.clr = true
    return ev

  syncEnergy: (forceUpdate) ->
    this.costEnergy()
    return {
      NTF:Event_UpdateEnergy,
      arg : {
        eng: @energy,
        tim: Math.floor(@energyTime.valueOf() / 1000)
      }
    }

  syncHero: (forceUpdate) ->
    ev = {
      NTF:Event_RoleUpdate,
      arg:{
        syn:this.heroVersion,
        act:getBasicInfo(@createHero())
      }
    }
    if forceUpdate then ev.arg.clr = true
    
    return ev

  syncDungeon: (forceUpdate) ->
    dungeon = this.dungeon
    if dungeon == null then return []
    ev = {
      NTF:Event_UpdateDungeon,
      arg:{
        pat:this.team,
        stg:dungeon.stage
      }
    }
    if forceUpdate then ev.arg.clr = true

    return ev

  syncCampaign: (forceUpdate) ->
    all = queryTable(TABLE_CAMPAIGN)
    ret = { NTF: Event_CampaignUpdate, arg: {act: [], syn: 0}}
    for campaign, cfg of all when cfg.show
      { config, level } = @getCampaignConfig(campaign)
      if not config? then continue
      r = {
        title: config.title,
        desc: config.description,
        banner: config.banner
      }
      r.date = config.dateDescription if config.dateDescription?
      r.prz = level.award if level.award
      ret.arg.act.push(r)
    return [ret]

  syncFlags: (forceUpdate) ->
    arg = {
      clr: true
    }
    for key, val of @flags
      arg[key] = val
    return {
      NTF: Event_UpdateFlags,
      arg: arg
    }

  syncQuest: (forceUpdate) ->
    ret = packQuestEvent(@quests, null, this.questVersion)
    if forceUpdate then ret.arg.clr = true
    return ret

  notifyVersions: () ->
    translateTable = {
      inventoryVersion : 'inv',
      heroVersion : 'act',
      #//dungeonVersion : 'dgn',
      stageVersion : 'stg',
      questVersion : 'qst'
    }

    versions = grabAndTranslate(this, translateTable)
    return {
      NTF : Event_SyncVersions,
      arg :versions
    }

playerMessageFilter = (oldMessage, newMessage, name) ->
  message = newMessage
  messageIDMap = {}
  friendMap = {}
  if oldMessage
    oldMessage.forEach((msg, index) ->
      return false unless msg?
      messageIDMap[msg.messageID] = true
      if msg.type is MESSAGE_TYPE_FriendApplication then friendMap[msg.name] = msg
    )
    message = message.filter((msg) ->
      return false unless msg?
      if messageIDMap[msg.messageID] then return false
      if msg.type == MESSAGE_TYPE_FriendApplication
        if friendMap[msg.name]
          if name then dbLib.removeMessage(name, msg.messageID)
          return false
 
        friendMap[msg.name] = msg
      return true
    )

  return message

#///////////////////////////////// item
createItem = (item) ->
  if Array.isArray(item)
    return ({item: createItem(e.item), count: e.count} for e in item)
  else if typeof item is 'number'
    return new itemLib.Item(item)
  else
    return item

itemLib = require('./item')
class PlayerEnvironment extends Environment
  constructor: (@player) ->

  aquireItem: (item, count, allOrFail) ->
    count = count ? 1
    item = createItem(item)
    showMeTheStack() unless item?
    return [] unless item?

    return {version: @player.inventoryVersion, ret: @player?.inventory.add(item, count, allOrFail)}

  removeItem: (item, count, slot, allorfail) ->
    return {ret: @player?.inventory.remove(item, count, slot, allorfail), version: @player.inventoryVersion}

  translateAction: (cmd) ->
    return [] unless cmd?
    ret = []
    ret = cmd.output() if cmd.output()?

    for i, routine of cmd.cmdRoutine
      ret = ret.concat(routine.output()) if routine?.output()?

    return ret.concat(@translateAction(cmd.nextCMD))

  translate: (cmd) -> @translateAction(cmd)

playerCommandStream = (cmd, player=null) ->
  env = new PlayerEnvironment(player)
  cmdStream = new CommandStream(cmd, null, playerCSConfig, env)
  return cmdStream

playerCSConfig = {
  ItemChange: {
    output: (env) ->
      ret = env.variable('ret')
      return [] unless ret and ret.length > 0
      items = ({sid: Number(e.slot), cid: e.id, stc: e.count} for e in ret)
      arg = { syn:env.variable('version') }
      arg.itm = items
      return [{NTF: Event_InventoryUpdateItem, arg: arg}]
  },
  AquireItem: {
    callback: (env) ->
      {ret, version} = env.aquireItem(env.variable('item'), env.variable('count'), env.variable('allorfail'))
      @routine({id: 'ItemChange', ret: ret, version: version})
  },
  RemoveItem: {
    callback: (env) ->
      {ret, version} = env.removeItem(env.variable('item'), env.variable('count'), env.variable('slot'), true)
      @routine({id: 'ItemChange', ret: ret, version: version})
  },
}

getVip = (rmb) ->
  tbl = queryTable(TABLE_VIP, "VIP", @abIndex)
  return {level: 0, cfg: {}} unless tbl?
  level = -1
  for i, lv of tbl.requirement when lv.rmb <= rmb
    level = i
  return {level: level, cfg: tbl.levels[level]}

registerConstructor(Player)
exports.Player = Player
exports.playerMessageFilter = playerMessageFilter
exports.getVip = getVip

(function() {
  var Wizard, calcFormular, getLevelConfig, getProperty, getSpellConfig, plusThemAll;

  requires('./define');

  getSpellConfig = function(spellID) {
    var cfg;
    cfg = queryTable(TABLE_SKILL, spellID);
    if (cfg == null) {
      return null;
    }
    return cfg.config;
  };

  getProperty = function(origin, backup) {
    if (backup != null) {
      return backup;
    } else {
      return origin;
    }
  };

  getLevelConfig = function(cfg, level) {
    level -= 1;
    if (cfg.levelConfig && (cfg.levelConfig[level] != null)) {
      return cfg.levelConfig[level];
    } else {
      return {};
    }
  };

  plusThemAll = function(config, env) {
    var e, k, sum, v, _i, _len, _ref;
    if (!((config != null) && (env != null))) {
      return 0;
    }
    sum = 0;
    if (Array.isArray(env)) {
      for (_i = 0, _len = env.length; _i < _len; _i++) {
        e = env[_i];
        sum += plusThemAll(config, e);
      }
    } else {
      sum = (_ref = config.c) != null ? _ref : 0;
      for (k in config) {
        v = config[k];
        if (env[k] != null) {
          sum += env[k] * v;
        }
      }
    }
    return sum;
  };

  calcFormular = function(e, s, t, config) {
    var c;
    c = config.c ? config.c : 0;
    return Math.ceil(plusThemAll(config.environment, e) + plusThemAll(config.src, s) + plusThemAll(config.tar, t) + c);
  };

  Wizard = (function() {
    function Wizard() {
      this.wSpellDB = {};
      this.wTriggers = {};
      this.wSpellMutex = {};
      this.wPreBuffState = {
        rs: BUFF_TYPE_NONE,
        ds: BUFF_TYPE_NONE,
        hs: BUFF_TYPE_NONE
      };
    }

    Wizard.prototype.faction = function(newFaction) {
      if (newFaction != null) {
        this.faction = newFaction;
      }
      return this.faction;
    };

    Wizard.prototype.installSpell = function(spellID, level, cmd, delay) {
      var cfg, levelConfig;
      if (delay == null) {
        delay = 0;
      }
      cfg = getSpellConfig(spellID);
      if (!((level != null) > 0)) {
        level = 1;
      }
      if (cfg == null) {
        return false;
      }
      levelConfig = getLevelConfig(cfg, level);
      if (this.wSpellDB[spellID]) {
        this.removeSpell(spellID, cmd);
      }
      this.wSpellDB[spellID] = {
        level: level,
        delay: delay
      };
      this.setupTriggerCondition(spellID, cfg.triggerCondition, levelConfig, cmd);
      this.setupAvailableCondition(spellID, cfg.availableCondition, levelConfig, cmd);
      this.doAction(this.wSpellDB[spellID], cfg.installAction, levelConfig, this.selectTarget(cfg, cmd), cmd);
      return this.spellStateChanged(cmd);
    };

    Wizard.prototype.setupAvailableCondition = function(spellID, conditions, level, cmd) {
      var limit, thisSpell, _i, _len, _results;
      if (!conditions) {
        return false;
      }
      thisSpell = this.wSpellDB[spellID];
      _results = [];
      for (_i = 0, _len = conditions.length; _i < _len; _i++) {
        limit = conditions[_i];
        switch (limit.type) {
          case 'effectCount':
            _results.push(thisSpell.effectCount = 0);
            break;
          case 'tick':
            if (thisSpell.tick == null) {
              thisSpell.tick = {};
            }
            _results.push(thisSpell.tick[limit.tickType] = 0);
            break;
          case 'event':
            _results.push(this.installTrigger(spellID, limit.event));
            break;
          default:
            _results.push(void 0);
        }
      }
      return _results;
    };

    Wizard.prototype.setupTriggerCondition = function(spellID, conditions, level, cmd) {
      var limit, thisSpell, _i, _len, _results;
      if (conditions == null) {
        return false;
      }
      thisSpell = this.wSpellDB[spellID];
      _results = [];
      for (_i = 0, _len = conditions.length; _i < _len; _i++) {
        limit = conditions[_i];
        switch (limit.type) {
          case 'countDown':
            _results.push(thisSpell.cd = 0);
            break;
          case 'event':
            _results.push(this.installTrigger(spellID, limit.event));
            break;
          default:
            _results.push(void 0);
        }
      }
      return _results;
    };

    Wizard.prototype.spellStateChanged = function(cmd) {
      if (cmd == null) {
        return false;
      }
      return typeof cmd.routine === "function" ? cmd.routine({
        id: 'SpellState',
        wizard: this,
        state: this.calcBuffState()
      }) : void 0;
    };

    Wizard.prototype.removeSpell = function(spellID, cmd) {
      var c, cfg, _i, _j, _len, _len1, _ref, _ref1;
      cfg = getSpellConfig(spellID);
      if (cfg.triggerCondition != null) {
        _ref = cfg.triggerCondition;
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          c = _ref[_i];
          if (c.type === 'event') {
            this.removeTrigger(spellID, c.event);
          }
        }
      }
      if (cfg.availableCondition != null) {
        _ref1 = cfg.availableCondition;
        for (_j = 0, _len1 = _ref1.length; _j < _len1; _j++) {
          c = _ref1[_j];
          if (c.type === 'event') {
            this.removeTrigger(spellID, c.event);
          }
        }
      }
      if (cfg.uninstallAction != null) {
        this.doAction(this.wSpellDB[spellID], cfg.uninstallAction, {}, this.selectTarget(cfg, cmd), cmd);
      }
      delete this.wSpellDB[spellID];
      return this.spellStateChanged(cmd);
    };

    Wizard.prototype.installTrigger = function(spellID, event) {
      var thisSpell;
      if (event == null) {
        return false;
      }
      thisSpell = this.wSpellDB[spellID];
      if (this.wTriggers[event] == null) {
        this.wTriggers[event] = [];
      }
      if (this.wTriggers[event].indexOf(spellID) === -1) {
        this.wTriggers[event].push(spellID);
      }
      if (thisSpell.eventCounters == null) {
        thisSpell.eventCounters = {};
      }
      return thisSpell.eventCounters[event] = 0;
    };

    Wizard.prototype.removeTrigger = function(spellID, event) {
      var id;
      if (!((event != null) && this.wTriggers[event])) {
        return false;
      }
      this.wTriggers[event] = (function() {
        var _i, _len, _ref, _results;
        _ref = this.wTriggers[event];
        _results = [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          id = _ref[_i];
          if (id !== spellID) {
            _results.push(id);
          }
        }
        return _results;
      }).call(this);
      if (!(this.wTriggers[event].length > 0)) {
        return delete this.wTriggers[event];
      }
    };

    Wizard.prototype.castSpell = function(spellID, level, cmd) {
      var canTrigger, cfg, delay, reason, target, thisSpell, _ref;
      cfg = getSpellConfig(spellID);
      thisSpell = this.wSpellDB[spellID];
      if (thisSpell != null) {
        level = thisSpell.level;
      }
      if (level == null) {
        return 'InvalidLevel';
      }
      level = getLevelConfig(cfg, level);
      target = this.selectTarget(cfg, cmd);
      _ref = this.triggerCheck(thisSpell, cfg.triggerCondition, level, target, cmd), canTrigger = _ref[0], reason = _ref[1];
      if (!canTrigger) {
        return reason;
      }
      this.doAction(thisSpell, cfg.action, level, target, cmd);
      this.updateCDOfSpell(spellID, true, cmd);
      if (!this.availableCheck(spellID, cfg, cmd)) {
        this.removeSpell(spellID, cmd);
      }
      delay = 0;
      if (thisSpell != null) {
        delay = thisSpell.delay;
      }
      if (cfg.basic != null) {
        if (typeof cmd.routine === "function") {
          cmd.routine({
            id: 'Casting',
            spell: cfg.basic,
            caster: this,
            castee: target,
            delay: delay
          });
        }
      }
      return true;
    };

    Wizard.prototype.onEvent = function(event, cmd) {
      var id, thisSpell, _i, _len, _ref, _results;
      if (this.wTriggers[event] == null) {
        return true;
      }
      _ref = this.wTriggers[event];
      _results = [];
      for (_i = 0, _len = _ref.length; _i < _len; _i++) {
        id = _ref[_i];
        thisSpell = this.wSpellDB[id];
        if (thisSpell != null) {
          thisSpell.eventCounters[event]++;
        }
        _results.push(this.castSpell(id, null, cmd));
      }
      return _results;
    };

    Wizard.prototype.clearSpellCD = function(spellID, cmd) {
      var thisSpell;
      if (!((spellID != null) && (this.wSpellDB[spellID] != null))) {
        return false;
      }
      thisSpell = this.wSpellDB[spellID];
      if ((thisSpell.cd != null) && thisSpell.cd !== 0) {
        thisSpell.cd = 0;
        if (this.isHero()) {
          return typeof cmd.routine === "function" ? cmd.routine({
            id: 'SpellCD',
            cdInfo: thisSpell.cd
          }) : void 0;
        }
      }
    };

    Wizard.prototype.updateCDOfSpell = function(spellID, isReset, cmd) {
      var c, cd, cdConfig, cfg, level, preCD, thisSpell;
      cfg = getSpellConfig(spellID);
      thisSpell = this.wSpellDB[spellID];
      if (!thisSpell) {
        return [false, 'NotLearned'];
      }
      if (!cfg.triggerCondition) {
        return [true, 'NoCD'];
      }
      if (!(this.health > 0)) {
        return [false, 'Dead'];
      }
      cdConfig = (function() {
        var _i, _len, _ref, _results;
        _ref = cfg.triggerCondition;
        _results = [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          c = _ref[_i];
          if (c.type === 'countDown') {
            _results.push(c);
          }
        }
        return _results;
      })();
      if (!(cdConfig.length > 0)) {
        return [true, 'NoCD'];
      }
      cdConfig = cdConfig[0];
      level = getLevelConfig(cfg, thisSpell.level);
      cd = getProperty(cdConfig.cd, level.cd);
      preCD = thisSpell.cd;
      if (isReset) {
        thisSpell.cd = cd;
      } else if (this.health <= 0) {
        thisSpell.cd = -1;
      } else {
        if (thisSpell.cd !== 0) {
          thisSpell.cd -= 1;
        }
      }
      if (thisSpell.cd !== preCD && this.isHero()) {
        return typeof cmd.routine === "function" ? cmd.routine({
          id: 'SpellCD',
          cdInfo: thisSpell.cd
        }) : void 0;
      }
    };

    Wizard.prototype.haveMutex = function(mutex) {
      return this.wSpellMutex[mutex] != null;
    };

    Wizard.prototype.setMutex = function(mutex, count) {
      return this.wSpellMutex[mutex] = count;
    };

    Wizard.prototype.tickMutex = function() {
      var count, mutex, _ref, _results;
      _ref = this.wSpellMutex;
      _results = [];
      for (mutex in _ref) {
        count = _ref[mutex];
        count -= 1;
        this.wSpellMutex[mutex] = count;
        if (count === 0) {
          _results.push(delete this.wSpellMutex[mutex]);
        } else {
          _results.push(void 0);
        }
      }
      return _results;
    };

    Wizard.prototype.tickSpell = function(tickType, cmd) {
      var spellID, thisSpell, _ref, _results;
      this.tickMutex();
      _ref = this.wSpellDB;
      _results = [];
      for (spellID in _ref) {
        thisSpell = _ref[spellID];
        this.updateCDOfSpell(spellID, false, cmd);
        if ((thisSpell.tick != null) && (thisSpell.tick[tickType] != null) && (tickType != null)) {
          thisSpell.tick[tickType] += 1;
        }
        if (!this.availableCheck(spellID, getSpellConfig(spellID), cmd)) {
          _results.push(this.removeSpell(spellID, cmd));
        } else {
          _results.push(void 0);
        }
      }
      return _results;
    };

    Wizard.prototype.availableCheck = function(spellID, cfg, cmd) {
      var conditions, count, level, limit, thisSpell, _i, _len, _ref;
      thisSpell = this.wSpellDB[spellID];
      if (!thisSpell) {
        return false;
      }
      conditions = cfg.availableCondition;
      if (!conditions) {
        return true;
      }
      level = getLevelConfig(cfg, thisSpell.level);
      for (_i = 0, _len = conditions.length; _i < _len; _i++) {
        limit = conditions[_i];
        switch (limit.type) {
          case 'effectCount':
            if (!(thisSpell.effectCount < getProperty(limit.count, level.count))) {
              return false;
            }
            break;
          case 'tick':
            if (!(thisSpell.tick[limit.tickType] < getProperty(limit.ticks, level.ticks))) {
              return false;
            }
            break;
          case 'event':
            count = (_ref = getProperty(limit.eventCount, level.eventCount)) != null ? _ref : 1;
            if (!(thisSpell.eventCounters[limit.event] < count)) {
              return false;
            }
        }
      }
      return true;
    };

    Wizard.prototype.calcBuffState = function() {
      var cfg, k, res, roleState, s, spellID, thisSpell, _ref;
      roleState = {
        rs: BUFF_TYPE_NONE,
        ds: BUFF_TYPE_NONE,
        hs: BUFF_TYPE_NONE
      };
      _ref = this.wSpellDB;
      for (spellID in _ref) {
        thisSpell = _ref[spellID];
        cfg = getSpellConfig(spellID);
        if (cfg.buffType == null) {
          continue;
        }
        switch (cfg.buffType) {
          case 'RoleDebuff':
            roleState.rs = BUFF_TYPE_DEBUFF;
            break;
          case 'HealthDebuff':
            roleState.hs = BUFF_TYPE_DEBUFF;
            break;
          case 'AttackDebuff':
            roleState.ds = BUFF_TYPE_DEBUFF;
            break;
          case 'HealthBuff':
            roleState.hs = BUFF_TYPE_BUFF;
            break;
          case 'AttackBuff':
            roleState.ds = BUFF_TYPE_BUFF;
            break;
          case 'RoleBuff':
            roleState.rs = BUFF_TYPE_BUFF;
        }
      }
      res = {};
      for (k in roleState) {
        s = roleState[k];
        if (this.wPreBuffState[k] !== s) {
          res[k] = s;
        }
        switch (k) {
          case 'hs':
            res.hp = this.health;
            break;
          case 'ds':
            res.dc = this.attack;
        }
      }
      this.wPreBuffState = roleState;
      return res;
    };

    Wizard.prototype.selectTarget = function(cfg, cmd) {
      var a, b, blocks, count, env, filter, m, p, pool, t, tmp, x, y, _i, _j, _k, _len, _len1, _len2, _ref, _ref1, _ref2, _ref3, _ref4;
      if (!((cfg.targetSelection != null) && cfg.targetSelection.pool)) {
        return [];
      }
      if (!(cfg.targetSelection.pool === 'Self' || (cmd != null))) {
        return [];
      }
      if (cmd != null) {
        env = cmd.getEnvironment();
      }
      switch (cfg.targetSelection.pool) {
        case 'Enemy':
          pool = env.getEnemyOf(this);
          break;
        case 'Team':
          pool = env.getTeammateOf(this).concat(this);
          break;
        case 'Teammate':
          pool = env.getTeammateOf(this);
          break;
        case 'Self':
          pool = this;
          break;
        case 'Target':
          pool = env.variable('tar');
          break;
        case 'Source':
        case 'Attacker':
          pool = env.variable('src');
          break;
        case 'SamePosition':
          pool = env.getBlock(this.pos).getRef();
          break;
        case 'RoleID':
          pool = (function() {
            var _i, _len, _ref, _results;
            _ref = env.getObjects();
            _results = [];
            for (_i = 0, _len = _ref.length; _i < _len; _i++) {
              m = _ref[_i];
              if (m.id === cfg.targetSelection.roleID) {
                _results.push(m);
              }
            }
            return _results;
          })();
          break;
        case 'Block':
          blocks = cfg.targetSelection.blocks;
          pool = blocks != null ? (function() {
            var _i, _len, _results;
            _results = [];
            for (_i = 0, _len = blocks.length; _i < _len; _i++) {
              b = blocks[_i];
              _results.push(env.getBlock(b));
            }
            return _results;
          })() : env.getBlock();
      }
      if (pool == null) {
        pool = [];
      }
      if (!Array.isArray(pool)) {
        pool = [pool];
      }
      if ((cfg.targetSelection.filter != null) && pool.length > 0) {
        _ref = cfg.targetSelection.filter;
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          filter = _ref[_i];
          switch (filter) {
            case 'Alive':
              pool = (function() {
                var _j, _len1, _results;
                _results = [];
                for (_j = 0, _len1 = pool.length; _j < _len1; _j++) {
                  p = pool[_j];
                  if (p.health > 0) {
                    _results.push(p);
                  }
                }
                return _results;
              })();
              break;
            case 'Visible':
              pool = (function() {
                var _j, _len1, _results;
                _results = [];
                for (_j = 0, _len1 = pool.length; _j < _len1; _j++) {
                  p = pool[_j];
                  if (p.isVisible) {
                    _results.push(p);
                  }
                }
                return _results;
              })();
              break;
            case 'Hero':
              pool = (function() {
                var _j, _len1, _results;
                _results = [];
                for (_j = 0, _len1 = pool.length; _j < _len1; _j++) {
                  p = pool[_j];
                  if (p.isHero()) {
                    _results.push(p);
                  }
                }
                return _results;
              })();
              break;
            case 'Monster':
              pool = (function() {
                var _j, _len1, _results;
                _results = [];
                for (_j = 0, _len1 = pool.length; _j < _len1; _j++) {
                  p = pool[_j];
                  if (!p.isHero()) {
                    _results.push(p);
                  }
                }
                return _results;
              })();
              break;
            case 'SameBlock':
              pool = (function() {
                var _j, _len1, _results;
                _results = [];
                for (_j = 0, _len1 = pool.length; _j < _len1; _j++) {
                  p = pool[_j];
                  if (p.pos === this.pos) {
                    _results.push(p);
                  }
                }
                return _results;
              }).call(this);
          }
        }
      }
      count = (_ref1 = cfg.targetSelection.count) != null ? _ref1 : 1;
      if ((cfg.targetSelection.method != null) && pool.length > 0) {
        switch (cfg.targetSelection.method) {
          case 'Rand':
            pool = env.randMember(pool, count);
            if (!Array.isArray(pool)) {
              pool = [pool];
            }
            break;
          case 'LowHealth':
            pool = [
              pool.sort(function(a, b) {
                return a.health - b.health;
              })[0]
            ];
        }
      }
      if (cfg.targetSelection.anchor && (env != null)) {
        tmp = pool;
        pool = [];
        for (_j = 0, _len1 = tmp.length; _j < _len1; _j++) {
          t = tmp[_j];
          if (!t.isBlock) {
            t = env.getBlock(t.pos);
          }
          x = t.pos % Dungeon_Width;
          y = (t.pos - x) / Dungeon_Width;
          _ref2 = cfg.targetSelection.anchor;
          for (_k = 0, _len2 = _ref2.length; _k < _len2; _k++) {
            a = _ref2[_k];
            if ((0 <= (_ref3 = a.x + x) && _ref3 < Dungeon_Width) && (0 <= (_ref4 = a.y + y) && _ref4 < Dungeon_Height)) {
              pool.push(env.getBlock(a.x + x + (a.y + y) * Dungeon_Width));
            }
          }
        }
      }
      return pool;
    };

    Wizard.prototype.triggerCheck = function(thisSpell, conditions, level, target, cmd) {
      var env, from, limit, to, _i, _len, _ref, _ref1, _ref2;
      if (conditions == null) {
        return [true];
      }
      env = cmd.getEnvironment();
      for (_i = 0, _len = conditions.length; _i < _len; _i++) {
        limit = conditions[_i];
        switch (limit.type) {
          case 'chance':
            if (!env.chanceCheck(getProperty(limit.chance, level.chance))) {
              return [false, 'NotFortunate'];
            }
            break;
          case 'card':
            if (!env.haveCard(limit.id)) {
              return [false, 'NoCard'];
            }
            break;
          case 'alive':
            if (!(this.health > 0)) {
              return [false, 'Dead'];
            }
            break;
          case 'visible':
            if (!this.isVisible) {
              return [false, 'visible'];
            }
            break;
          case 'needTarget':
            if (target == null) {
              return [false, 'No target'];
            }
            break;
          case 'countDown':
            if (thisSpell == null) {
              return [false, 'NotLearned'];
            }
            if (!(thisSpell.cd <= 0)) {
              return [false, 'NotReady'];
            }
            break;
          case 'myMutex':
            if (this.haveMutex(limit.mutex)) {
              return [false, 'TargetMutex'];
            }
            break;
          case 'targetMutex':
            if (target == null) {
              return [false, 'NoTarget'];
            }
            if (target.some(function(t) {
              return t.haveMutex(limit.mutex);
            })) {
              return [false, 'TargetMutex'];
            }
            break;
          case 'event':
            if (thisSpell == null) {
              return [false, 'NotLearned'];
            }
            if ((limit.eventCount != null) && limit.eventCount > thisSpell.eventCounters[limit.event]) {
              return [false, 'EventCount'];
            }
            if (limit.reset) {
              thisSpell.eventCounters[limit.event] = 0;
            }
            break;
          case 'property':
            from = (_ref = limit.from) != null ? _ref : -Infinity;
            to = (_ref1 = limit.to) != null ? _ref1 : Infinity;
            if (!((limit.property != null) && (from < (_ref2 = this[limit.property]) && _ref2 < to))) {
              return [false, 'Property'];
            }
        }
      }
      return [true];
    };

    Wizard.prototype.getActiveSpell = function() {
      return -1;
    };

    Wizard.prototype.doAction = function(thisSpell, actions, level, target, cmd) {
      var a, c, cfg, delay, env, formular, formularResult, h, modifications, pos, property, spellID, src, t, val, variables, _buffType, _i, _j, _k, _l, _len, _len1, _len10, _len11, _len12, _len13, _len2, _len3, _len4, _len5, _len6, _len7, _len8, _len9, _m, _n, _o, _p, _q, _r, _ref, _ref1, _ref2, _ref3, _ref4, _s, _t, _u, _v;
      if (actions == null) {
        return false;
      }
      env = cmd != null ? cmd.getEnvironment() : void 0;
      for (_i = 0, _len = actions.length; _i < _len; _i++) {
        a = actions[_i];
        variables = {};
        if (env != null) {
          variables = env.variable();
        }
        if (getProperty(a.formular, level.formular) != null) {
          formularResult = calcFormular(variables, this, target, getProperty(a.formular, level.formular));
        }
        delay = 0;
        if (thisSpell != null) {
          delay = thisSpell.delay;
        }
        if (a.delay) {
          delay += typeof a.delay === 'number' ? a.delay : env.rand() * a.delay.base + env.rand() * a.delay.range;
        }
        switch (a.type) {
          case 'modifyVar':
            env.variable(a.x, formularResult);
            break;
          case 'ignoreHurt':
            env.variable('ignoreHurt', true);
            break;
          case 'replaceTar':
            env.variable('tar', this);
            break;
          case 'setTargetMutex':
            for (_j = 0, _len1 = target.length; _j < _len1; _j++) {
              t = target[_j];
              t.setMutex(getProperty(a.mutex, level.mutex), getProperty(a.count, level.count));
            }
            break;
          case 'setMyMutex':
            this.setMutex(getProperty(a.mutex, level.mutex), getProperty(a.count, level.count));
            break;
          case 'resetSpellCD':
            for (_k = 0, _len2 = target.length; _k < _len2; _k++) {
              t = target[_k];
              t.clearSpellCD(t.getActiveSpell(), cmd);
            }
            break;
          case 'ignoreCardCost':
            env.variable('ignoreCardCost', true);
            break;
          case 'dropItem':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'DropItem',
                list: a.dropList
              });
            }
            break;
          case 'rangeAttack':
          case 'attack':
            for (_l = 0, _len3 = target.length; _l < _len3; _l++) {
              t = target[_l];
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Attack',
                  src: this,
                  tar: t,
                  isRange: true
                });
              }
            }
            break;
          case 'showUp':
            for (_m = 0, _len4 = target.length; _m < _len4; _m++) {
              t = target[_m];
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'ShowUp',
                  tar: t
                });
              }
            }
            break;
          case 'costCard':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'CostCard',
                card: a.card
              });
            }
            break;
          case 'showExit':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'ShowExit'
              });
            }
            break;
          case 'resurrect':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'Resurrect',
                tar: target
              });
            }
            break;
          case 'randTeleport':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'TeleportObject',
                obj: this
              });
            }
            break;
          case 'kill':
            for (_n = 0, _len5 = target.length; _n < _len5; _n++) {
              t = target[_n];
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Kill',
                  tar: t
                });
              }
            }
            break;
          case 'shock':
            if (cmd != null) {
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Shock',
                  time: a.time,
                  delay: a.delay,
                  range: a.range
                });
              }
            }
            break;
          case 'blink':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'Blink',
                time: a.time,
                delay: a.delay,
                color: a.color
              });
            }
            break;
          case 'changeBGM':
            cmd.routine({
              id: 'ChangeBGM',
              music: a.music,
              repeat: a.repeat
            });
            break;
          case 'whiteScreen':
            cmd.routine({
              id: 'WhiteScreen',
              mode: a.mode,
              time: a.time,
              color: a.color
            });
            break;
          case 'endDungeon':
            cmd.routine({
              id: 'EndDungeon',
              result: a.result
            });
            break;
          case 'openBlock':
            cmd.routine({
              id: 'OpenBlock',
              block: a.block
            });
            break;
          case 'chainBlock':
            _ref = a.source;
            for (_o = 0, _len6 = _ref.length; _o < _len6; _o++) {
              src = _ref[_o];
              cmd.routine({
                id: 'ChainBlock',
                src: src,
                tar: a.target
              });
            }
            break;
          case 'castSpell':
            this.castSpell(a.spell, (_ref1 = a.level) != null ? _ref1 : 1, cmd);
            break;
          case 'playSound':
            cmd.routine({
              id: 'SoundEffect',
              sound: a.sound
            });
            break;
          case 'heal':
            if (a.self) {
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Heal',
                  src: this,
                  tar: this,
                  hp: formularResult
                });
              }
            } else {
              for (_p = 0, _len7 = target.length; _p < _len7; _p++) {
                t = target[_p];
                if (typeof cmd.routine === "function") {
                  cmd.routine({
                    id: 'Heal',
                    src: this,
                    tar: t,
                    hp: formularResult
                  });
                }
              }
            }
            break;
          case 'installSpell':
            for (_q = 0, _len8 = target.length; _q < _len8; _q++) {
              t = target[_q];
              delay = 0;
              if (thisSpell != null) {
                delay = thisSpell.delay;
              }
              if (a.delay != null) {
                delay += typeof a.delay === 'number' ? a.delay : a.delay.base + env.rand() * a.delay.range;
              }
              t.installSpell(getProperty(a.spell, level.spell), getProperty(a.level, level.level), cmd, delay);
            }
            break;
          case 'damage':
            for (_r = 0, _len9 = target.length; _r < _len9; _r++) {
              t = target[_r];
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Damage',
                  src: this,
                  tar: t,
                  damageType: a.damageType,
                  isRange: a.isRange,
                  damage: formularResult,
                  delay: delay
                });
              }
            }
            break;
          case 'playAction':
            if (a.pos === 'self') {
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'SpellAction',
                  motion: a.motion,
                  ref: this.ref
                });
              }
            } else if (a.pos === 'target') {
              for (_s = 0, _len10 = target.length; _s < _len10; _s++) {
                t = target[_s];
                if (typeof cmd.routine === "function") {
                  cmd.routine({
                    id: 'SpellAction',
                    motion: a.motion,
                    ref: t.ref
                  });
                }
              }
            }
            break;
          case 'playEffect':
            if (a.pos === 'self') {
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Effect',
                  delay: delay,
                  effect: a.effect,
                  pos: this.pos
                });
              }
            } else if (a.pos === 'target') {
              for (_t = 0, _len11 = target.length; _t < _len11; _t++) {
                t = target[_t];
                if (typeof cmd.routine === "function") {
                  cmd.routine({
                    id: 'Effect',
                    delay: delay,
                    effect: a.effect,
                    pos: t.pos
                  });
                }
              }
            } else if (typeof a.pos === 'number') {
              if (typeof cmd.routine === "function") {
                cmd.routine({
                  id: 'Effect',
                  delay: delay,
                  effect: a.effect,
                  pos: a.pos
                });
              }
            } else if (Array.isArray(a.pos)) {
              _ref2 = a.pos;
              for (_u = 0, _len12 = _ref2.length; _u < _len12; _u++) {
                pos = _ref2[_u];
                if (typeof cmd.routine === "function") {
                  cmd.routine({
                    id: 'Effect',
                    delay: delay,
                    effect: a.effect,
                    pos: pos
                  });
                }
              }
            }
            break;
          case 'delay':
            c = {
              id: 'Delay'
            };
            if (a.delay != null) {
              c.delay = a.delay;
            }
            cmd = cmd.next(c);
            break;
          case 'setProperty':
            modifications = getProperty(a.modifications, level.modifications);
            if (thisSpell.modifications == null) {
              thisSpell.modifications = {};
            }
            for (property in modifications) {
              formular = modifications[property];
              val = calcFormular(variables, this, null, formular);
              this[property] += val;
              if (thisSpell.modifications[property] == null) {
                thisSpell.modifications[property] = 0;
              }
              thisSpell.modifications[property] += val;
            }
            break;
          case 'resetProperty':
            _ref3 = thisSpell.modifications;
            for (property in _ref3) {
              val = _ref3[property];
              this[property] -= val;
            }
            delete thisSpell.modifications;
            break;
          case 'clearDebuff':
          case 'clearBuff':
            if (a.type === 'clearDebuff') {
              _buffType = ['RoleDebuff', 'HealthDebuff', 'AttackDebuff'];
            } else {
              _buffType = ['RoleBuff', 'HealthBuff', 'AttackBuff'];
            }
            for (_v = 0, _len13 = target.length; _v < _len13; _v++) {
              h = target[_v];
              _ref4 = h.wSpellDB;
              for (spellID in _ref4) {
                thisSpell = _ref4[spellID];
                cfg = getSpellConfig(spellID);
                if (_buffType.indexOf(cfg.buffType) !== -1) {
                  h.removeSpell(spellID, cmd);
                }
              }
            }
            break;
          case 'createMonster':
            c = {
              id: 'CreateObject',
              classID: getProperty(a.monsterID, level.monsterID),
              count: getProperty(a.objectCount, level.objectCount),
              withKey: getProperty(a.withKey, level.withKey),
              collectID: getProperty(a.collectID, level.collectID),
              effect: getProperty(a.effect, level.effect)
            };
            if (!a.randomPos) {
              c.pos = this.pos;
            }
            if (a.pos != null) {
              c.pos = a.pos;
            }
            if (typeof cmd.routine === "function") {
              cmd.routine(c);
            }
            break;
          case 'dialog':
            if (typeof cmd.routine === "function") {
              cmd.routine({
                id: 'Dialog',
                dialogId: a.dialogId
              });
            }
        }
      }
      if ((thisSpell != null ? thisSpell.effectCount : void 0) != null) {
        return thisSpell.effectCount += 1;
      }
    };

    return Wizard;

  })();

  exports.Wizard = Wizard;

  exports.fileVersion = -1;

}).call(this);

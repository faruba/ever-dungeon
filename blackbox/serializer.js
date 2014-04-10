(function() {
  var Serializer, g_attr_constructorTable, generateMonitor, objectlize, registerConstructor;

  generateMonitor = function(obj) {
    return function(key, val) {
      return obj.s_attr_dirtyFlag[key] = true;
    };
  };

  Serializer = (function() {
    function Serializer() {
      this.s_attr_to_save = [];
      this.s_attr_dirtyFlag = {};
      this.s_attr_monitor = generateMonitor(this);
      Object.defineProperty(this, 's_attr_to_save', {
        enumerable: false,
        writable: true
      });
      Object.defineProperty(this, 's_attr_dirtyFlag', {
        enumerable: false,
        writable: true
      });
      Object.defineProperty(this, 's_attr_monitor', {
        enumerable: false,
        writable: false
      });
    }

    Serializer.prototype.attrSave = function(key, val) {
      if (this.s_attr_to_save.indexOf(key) !== -1) {
        return false;
      }
      this[key] = val;
      tap(this, key, this.s_attr_monitor);
      return this.s_attr_to_save.push(key);
    };

    Serializer.prototype.versionControl = function(versionKey, keys) {
      var key, ver, versionIncr, _i, _j, _len, _len1, _ref, _results;
      if (!Array.isArray(keys)) {
        keys = [keys];
      }
      for (_i = 0, _len = keys.length; _i < _len; _i++) {
        key = keys[_i];
        this.attrSave(key);
      }
      ver = (_ref = this[versionKey]) != null ? _ref : 1;
      this.attrSave(versionKey, ver);
      versionIncr = (function(_this) {
        return function() {
          return _this[versionKey]++;
        };
      })(this);
      _results = [];
      for (_j = 0, _len1 = keys.length; _j < _len1; _j++) {
        key = keys[_j];
        _results.push(tap(this, key, versionIncr));
      }
      return _results;
    };

    Serializer.prototype.getConstructor = function() {
      return g_attr_constructorTable[this.constructor.name];
    };

    Serializer.prototype.dump = function() {
      var key, ret, val, _i, _len, _ref;
      ret = {
        _constructor_: this.constructor.name,
        save: {}
      };
      _ref = this.s_attr_to_save;
      for (_i = 0, _len = _ref.length; _i < _len; _i++) {
        key = _ref[_i];
        val = this[key];
        if (Array.isArray(val)) {
          ret.save[key] = val.map(function(e) {
            if ((e != null ? e.dump : void 0) != null) {
              return e.dump();
            } else {
              return e;
            }
          });
        } else {
          ret.save[key] = (val != null ? val.dump : void 0) != null ? val.dump() : val;
        }
      }
      ret.save = JSON.parse(JSON.stringify(ret.save));
      return ret;
    };

    Serializer.prototype.restore = function(data) {
      var k, v;
      if (data == null) {
        return this;
      }
      if (typeof data === 'string') {
        data = JSON.parse(data);
      }
      for (k in data) {
        v = data[k];
        if (v != null) {
          if (v._constructor_ != null) {
            this.attrSave(k, objectlize(v));
          } else if (Array.isArray(v)) {
            this.attrSave(k, v.map(function(e) {
              if ((e != null ? e._constructor_ : void 0) != null) {
                return objectlize(e);
              } else {
                return e;
              }
            }));
          } else {
            this.attrSave(k, v);
          }
        }
      }
      return this;
    };

    Serializer.prototype.dumpChanged = function() {
      var key, ret, val, _ref;
      ret = null;
      _ref = this.s_attr_dirtyFlag;
      for (key in _ref) {
        val = _ref[key];
        if (ret == null) {
          ret = {};
        }
        if (this[key].dump) {
          ret[key] = this[key].dump();
        } else if (Array.isArray(this[key])) {
          ret[key] = this[key].map(function(v) {
            if (v != null ? v.dump : void 0) {
              return v.dump();
            } else {
              return v;
            }
          });
        } else {
          ret[key] = this[key];
        }
      }
      this.s_attr_dirtyFlag = {};
      if (ret) {
        ret = JSON.parse(JSON.stringify(ret));
      }
      return ret;
    };

    return Serializer;

  })();

  objectlize = function(data) {
    var o;
    if ((data != null ? data._constructor_ : void 0) == null) {
      throw 'No constructor';
    }
    if (!g_attr_constructorTable[data._constructor_]) {
      throw 'No constructor:' + data._constructor_;
    }
    o = new g_attr_constructorTable[data._constructor_]();
    o.restore(data.save);
    if (o.initialize != null) {
      o.initialize();
    }
    return o;
  };

  registerConstructor = function(func) {
    var constructor;
    constructor = func.prototype.constructor;
    if (typeof constructor === 'function') {
      return g_attr_constructorTable[constructor.name] = func;
    }
  };

  g_attr_constructorTable = {};

  exports.Serializer = Serializer;

  exports.registerConstructor = registerConstructor;

  exports.objectlize = objectlize;

  exports.fileVersion = -1;

}).call(this);

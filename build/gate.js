(function() {
  var SimpleProtocolDecoder, SimpleProtocolEncoder, async, backendManager, net, startSocketIOServer, startTcpServer, _ref;

  _ref = require('./requestStream'), SimpleProtocolDecoder = _ref.SimpleProtocolDecoder, SimpleProtocolEncoder = _ref.SimpleProtocolEncoder;

  require('./define');

  async = require('async');

  net = require('net');

  startSocketIOServer = function(servers, port) {
    var io;
    io = require('socket.io');
    return io.listen(port).on('connection', function(socket) {
      console.log('Connection');
      socket.encoder = new SimpleProtocolEncoder();
      socket.decoder = new SimpleProtocolDecoder();
      socket.encoder.setFlag('size');
      socket.server = backendManager.createConnection(socket);
      if (socket.server == null) {
        return;
      }
      socket.encoder.pipe(socket.server);
      socket.server.pipe(socket.decoder);
      socket.decoder.on('request', function(request) {
        return socket.emit('response', request);
      });
      return socket.on('request', function(request) {
        console.log('reqeust', request);
        return socket.encoder.writeObject(request);
      });
    }).set('log level', 0);
  };

  startTcpServer = function(port, backendManager) {
    var server;
    server = net.createServer(function(c) {
      c.decoder = new SimpleProtocolDecoder();
      c.encoder = new SimpleProtocolEncoder();
      c.encoder.setFlag('size');
      c.pipe(c.decoder);
      c.server = backendManager.createConnection(c);
      if (c.server == null) {
        return;
      }
      c.encoder.pipe(c.server);
      c.server.pipe(c);
      return c.decoder.on('request', function(request) {
        if (request) {
          request.address = {
            ip: c.remoteAddress,
            port: c.remotePort
          };
          return c.encoder.writeObject(request);
        } else {
          c.destroy();
          return c = null;
        }
      });
    });
    server.listen(port, console.log);
    return server.on('error', console.log);
  };

  backendManager = {
    currIndex: 0,
    backends: [],
    updateBackendStatus: function() {
      return this.backends.forEach(function(e) {
        var s;
        if (!e.alive) {
          s = net.connect(e.port, e.ip);
          s.on('connect', function() {
            e.alive = true;
            return console.log('Connection On', e);
          });
          s.on('error', function(err) {
            return e.alive = false;
          });
          s.on('end', function(err) {
            e.alive = false;
            return console.log('Connection Lost', e);
          });
          return s = null;
        }
      });
    },
    getAliveConnection: function() {
      var count, i, server, servers, _i;
      count = this.backends.length;
      servers = this.backends;
      for (i = _i = 1; 1 <= count ? _i <= count : _i >= count; i = 1 <= count ? ++_i : --_i) {
        if (!servers[(i + this.currIndex) % count].alive) {
          continue;
        }
        server = servers[(i + this.currIndex) % count];
        this.currIndex = (this.currIndex + 1) % count;
        return server;
      }
      return null;
    },
    createConnection: function(socket) {
      var nc, releaseSocket, server;
      server = this.getAliveConnection();
      if (server != null) {
        nc = net.connect(server.port, server.ip);
      }
      releaseSocket = function() {
        if (nc) {
          nc.destroy();
          nc = null;
        }
        return socket.destroy();
      };
      if (nc) {
        nc.on('end', releaseSocket);
        nc.on('error', releaseSocket);
      }
      socket.on('error', releaseSocket);
      socket.on('end', releaseSocket);
      return nc;
    },
    init: function(servers) {
      this.backends = servers.map(function(s, id) {
        return {
          ip: s.ip,
          port: s.port,
          alive: false
        };
      });
      this.updateBackendStatus();
      return setInterval(((function(_this) {
        return function() {
          return _this.updateBackendStatus();
        };
      })(this)), 10000);
    }
  };

  initGlobalConfig(null, function() {
    var gServerConfig, gServerID;
    gServerID = queryTable(TABLE_CONFIG, 'ServerID');
    gServerConfig = queryTable(TABLE_CONFIG, 'ServerConfig')[gServerID];
    backendManager.init(gServerConfig.Gate);
    return startTcpServer(7757, backendManager);
  });

}).call(this);

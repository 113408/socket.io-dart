/**
 * socket.dart
 *
 * Purpose:
 *
 * Description:
 *
 * History:
 *    17/02/2017, Created by jumperchen
 *
 * Copyright (C) 2017 Potix Corporation. All Rights Reserved.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:socket_io/src/engine/server.dart';
import 'package:socket_io/src/engine/parser/packet.dart';
import 'package:socket_io/src/engine/transport/transports.dart';
import 'package:socket_io/src/util/event_emitter.dart';

/**
 * Client class (abstract).
 *
 * @api private
 */
class Socket extends EventEmitter {
  static final Logger _logger = new Logger("socket_io:engine/Socket");
  String id;
  Server server;
  Transport transport;
  bool upgrading;
  bool upgraded;
  String readyState;
  List<Packet> writeBuffer;
  List<Function> packetsFn;
  List<Function> sentCallbackFn;
  List cleanupFn;
  HttpRequest req;
  InternetAddress remoteAddress;
  Timer checkIntervalTimer;
  Timer upgradeTimeoutTimer;
  Timer pingTimeoutTimer;

  Socket(this.id, this.server, this.transport, this.req) {
    this.upgrading = false;
    this.upgraded = false;
    this.readyState = 'opening';
    this.writeBuffer = <Packet>[];
    this.packetsFn = [];
    this.sentCallbackFn = [];
    this.cleanupFn = [];

    // Cache IP since it might not be in the req later
    this.remoteAddress = req.connectionInfo.remoteAddress;

    this.checkIntervalTimer = null;
    this.upgradeTimeoutTimer = null;
    this.pingTimeoutTimer = null;

    this.setTransport(transport);
    this.onOpen();
  }

  /**
   * Called upon transport considered open.
   *
   * @api private
   */

  onOpen() {
    this.readyState = 'open';

    // sends an `open` packet
    this.transport.sid = this.id;
    this.sendPacket('open', data: JSON.encode({
      'sid': this.id,
      'upgrades': this.getAvailableUpgrades(),
      'pingInterval': this.server.pingInterval,
      'pingTimeout': this.server.pingTimeout
    }));

//    if (this.server.initialPacket != null) {
//      this.sendPacket('message', data: this.server.initialPacket);
//    }

    this.emit('open');
    this.setPingTimeout();
  }

  /**
   * Called upon transport packet.
   *
   * @param {Object} packet
   * @api private
   */

  onPacket(Packet packet) {
    if ('open' == this.readyState) {
      // export packet event
      _logger.info('packet');
      this.emit('packet', packet);

      // Reset ping timeout on any packet, incoming data is a good sign of
      // other side's liveness
      this.setPingTimeout();

      switch (packet.type) {
        case 'ping':
          _logger.info('got ping');
          this.sendPacket('pong');
          this.emit('heartbeat');
          break;

        case 'error':
          this.onClose('parse error');
          break;

        case 'message':
          this.emit('data', packet.data);
          this.emit('message', packet.data);
          break;
      }
    } else {
      _logger.info('packet received with closed socket');
    }
  }

  /**
   * Called upon transport error.
   *
   * @param {Error} error object
   * @api private
   */
  onError(err) {
    _logger.info('transport error');
    this.onClose('transport error', err);
  }

  /**
   * Sets and resets ping timeout timer based on client pings.
   *
   * @api private
   */
  setPingTimeout() {
    if (this.pingTimeoutTimer != null) {
      this.pingTimeoutTimer.cancel();
    }
    this.pingTimeoutTimer = new Timer(new Duration(
        milliseconds: this.server.pingInterval + this.server.pingTimeout), () {
      this.onClose('ping timeout');
    });
  }

  /**
   * Attaches handlers for the given transport.
   *
   * @param {Transport} transport
   * @api private
   */
  setTransport(Transport transport) {
    var onError = this.onError;
    var onPacket = this.onPacket;
    var flush = (_) => this.flush();
    var onClose = (_) {
      this.onClose('transport close');
    };

    this.transport = transport;
    this.transport.once('error', onError);
    this.transport.on('packet', onPacket);
    this.transport.on('drain', flush);
    this.transport.once('close', onClose);
    // this function will manage packet events (also message callbacks)
    this.setupSendCallback();

    this.cleanupFn.add(() {
      transport.off('error', onError);
      transport.off('packet', onPacket);
      transport.off('drain', flush);
      transport.off('close', onClose);
    });
  }

  /**
   * Upgrades socket to the given transport
   *
   * @param {Transport} transport
   * @api private
   */
  maybeUpgrade(transport) {
    _logger.info('might upgrade socket transport from ${this.transport
        .name} to ${transport.name}');

    this.upgrading = true;
    Map<String, Function> cleanupFn = {};
    // set transport upgrade timer
    this.upgradeTimeoutTimer =
    new Timer(new Duration(milliseconds: this.server.upgradeTimeout), () {
      _logger.info('client did not complete upgrade - closing transport');
      cleanupFn['cleanup']();
      if ('open' == transport.readyState) {
        transport.close();
      }
    });

    // we force a polling cycle to ensure a fast upgrade
    var check = () {
      if ('polling' == this.transport.name && this.transport.writable == true) {
        _logger.info('writing a noop packet to polling for fast upgrade');
        this.transport.send([{ 'type': 'noop'}]);
      }
    };

    var onPacket = (packet) {
      if ('ping' == packet.type && 'probe' == packet.data) {
        transport.send([{ 'type': 'pong', 'data': 'probe'}]);
        this.emit('upgrading', transport);
        if (this.checkIntervalTimer != null) {
          this.checkIntervalTimer.cancel();
        }
        this.checkIntervalTimer =
        new Timer.periodic(new Duration(milliseconds: 100), (_) => check());
      } else if ('upgrade' == packet.type && this.readyState != 'closed') {
        _logger.info('got upgrade packet - upgrading');
        cleanupFn['cleanup']();
        this.transport.discard();
        this.upgraded = true;
        this.clearTransport();
        this.setTransport(transport);
        this.emit('upgrade', transport);
        this.setPingTimeout();
        this.flush();
        if (this.readyState == 'closing') {
          transport.close(() {
            this.onClose('forced close');
          });
        }
      } else {
        cleanupFn['cleanup']();
        transport.close();
      }
    };

    var onError = (err) {
      _logger.info('client did not complete upgrade - %s', err);
      cleanupFn['cleanup']();
      transport.close();
      transport = null;
    };

    var onTransportClose = (_) {
      onError('transport closed');
    };

    var onClose = (_) {
      onError('socket closed');
    };


    var cleanup = () {
      this.upgrading = false;
      this.checkIntervalTimer?.cancel();
      this.checkIntervalTimer = null;

      this.upgradeTimeoutTimer?.cancel();
      this.upgradeTimeoutTimer = null;

      transport.off('packet', onPacket);
      transport.off('close', onTransportClose);
      transport.off('error', onError);
      this.off('close', onClose);
    };
    cleanupFn['cleanup'] = cleanup; // define it later
    transport.on('packet', onPacket);
    transport.once('close', onTransportClose);
    transport.once('error', onError);

    this.once('close', onClose);
  }

  /**
   * Clears listeners and timers associated with current transport.
   *
   * @api private
   */
  clearTransport() {
    var cleanup;

    var toCleanUp = this.cleanupFn.length;

    for (var i = 0; i < toCleanUp; i++) {
      cleanup = this.cleanupFn.removeAt(0);
      cleanup();
    }

    // silence further transport errors and prevent uncaught exceptions
    this.transport.on('error', (_) {
      _logger.info('error triggered by discarded transport');
    });

    // ensure transport won't stay open
    this.transport.close();

    this.pingTimeoutTimer?.cancel();
  }

  /**
   * Called upon transport considered closed.
   * Possible reasons: `ping timeout`, `client error`, `parse error`,
   * `transport error`, `server close`, `transport close`
   */
  onClose(reason, [description]) {
    if ('closed' != this.readyState) {
      this.readyState = 'closed';
      this.pingTimeoutTimer?.cancel();
      this.checkIntervalTimer?.cancel();
      this.checkIntervalTimer = null;
      this.upgradeTimeoutTimer?.cancel();

      // clean writeBuffer in next tick, so developers can still
      // grab the writeBuffer on 'close' event
      Timer.run(() {
        this.writeBuffer = [];
      });
      this.packetsFn = [];
      this.sentCallbackFn = [];
      this.clearTransport();
      this.emit('close', [reason, description]);
    }
  }

  /**
   * Setup and manage send callback
   *
   * @api private
   */
  setupSendCallback() {
    // the message was sent successfully, execute the callback
    var onDrain = (_) {
      if (this.sentCallbackFn.isNotEmpty) {
        var seqFn = this.sentCallbackFn[0];
        if (seqFn is Function) {
          _logger.info('executing send callback');
          seqFn(this.transport);
        } /** else if (Array.isArray(seqFn)) {
            _logger.info('executing batch send callback');
            for (var l = seqFn.length, i = 0; i < l; i++) {
            if ('function' === typeof seqFn[i]) {
            seqFn[i](self.transport);
            }
            }
            }*/
      }
    };

    this.transport.on('drain', onDrain);

    this.cleanupFn.add(() {
      this.transport.off('drain', onDrain);
    });
  }

  /**
   * Sends a message packet.
   *
   * @param {String} message
   * @param {Object} options
   * @param {Function} callback
   * @return {Socket} for chaining
   * @api public
   */
  send(data, options, [callback]) => write(data, options, callback);
  write(data, options, [callback]) {
    this.sendPacket('message', data: data, options: options, callback: callback);
    return this;
  }

  /**
   * Sends a packet.
   *
   * @param {String} packet type
   * @param {String} optional, data
   * @param {Object} options
   * @api private
   */
  sendPacket(type, {data, options, callback}) {
    options = options ?? {};
    options['compress'] = false != options['compress'];

    if ('closing' != this.readyState && 'closed' != this.readyState) {
//      _logger.info('sending packet "%s" (%s)', type, data);

      var packet = {'type': type, 'options': options};
      if (data != null) packet['data'] = data;

      // exports packetCreate event
      this.emit('packetCreate', packet);

      this.writeBuffer.add(new Packet.fromJSON(packet));

      // add send callback to object, if defined
      if (callback != null) this.packetsFn.add(callback);

      this.flush();
    }
  }

  /**
   * Attempts to flush the packets buffer.
   *
   * @api private
   */
  flush() {
    if ('closed' != this.readyState && this.transport.writable == true &&
        this.writeBuffer.length > 0) {
      _logger.info('flushing buffer to transport');
      this.emit('flush', this.writeBuffer);
      this.server.emit('flush', [this, this.writeBuffer]);
      var wbuf = this.writeBuffer;
      this.writeBuffer = [];
      if (this.transport.supportsFraming == false) {
        this.sentCallbackFn.add((_) => this.packetsFn.forEach((f) => f(_)));
      } else {
        this.sentCallbackFn.addAll(this.packetsFn);
      }
      this.packetsFn = [];
      this.transport.send(wbuf);
      this.emit('drain');
      this.server.emit('drain', this);
    }
  }

  /**
   * Get available upgrades for this socket.
   *
   * @api private
   */
  getAvailableUpgrades() {
    var availableUpgrades = [];
    var allUpgrades = this.server.upgrades(this.transport.name);
    for (var i = 0, l = allUpgrades.length; i < l; ++i) {
      var upg = allUpgrades[i];
      if (this.server.transports.contains(upg)) {
        availableUpgrades.add(upg);
      }
    }
    return availableUpgrades;
  }

  /**
   * Closes the socket and underlying transport.
   *
   * @param {Boolean} optional, discard
   * @return {Socket} for chaining
   * @api public
   */

  close([discard = false]) {
    if ('open' != this.readyState) return;
    this.readyState = 'closing';

    if (this.writeBuffer.isNotEmpty) {
      this.once('drain', (_) => this.closeTransport(discard));
      return;
    }

    this.closeTransport(discard);
  }

  /**
   * Closes the underlying transport.
   *
   * @param {Boolean} discard
   * @api private
   */
  closeTransport(discard) {
    if (discard == true) this.transport.discard();
    this.transport.close(() => this.onClose('forced close'));
  }
}
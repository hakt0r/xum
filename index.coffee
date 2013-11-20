#!/usr/bin/env coffee
#
### Xum - Cross Uplink Multiplexer
#    
    Bond multiple uplinks
    c) 2008-2013 Sebastian Glaser
    c) 1999-2005 nd-kt-nr

    Version: 0.33.5-retrogod
    License: GNU GPL Version 3

    node-xum/0.33.5-retrogod  : c) 2013 Sebastian Glaser

    based on:
    mudx-ssh/0.22.7-goldfinger: c) 2008-2013 Sebastian Glaser
    uplinks /0.11.9-rubberglue: c) 1999-2005 nd-kt-nr

  This file is part of Xum.

  Xum is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2, or (at your option)
  any later version.

  Xum is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this software; see the file COPYING.  If not, write to
  the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
  Boston, MA 02111-1307 USA
  
  http://www.gnu.org/licenses/gpl.html ###

os  = require 'os'
fs  = require 'fs'
cp  = require 'child_process'
net = require "net"
ync = require 'ync'
dgram = require 'dgram'
colors = require 'colors'
optimist = require 'optimist'
Storable = require 'storable'
{ script, scriptline } = xl = require 'xumlib'

hostname = null
path     = __filename
args     = optimist.argv._
argv     = optimist.argv
HOME     = argv.config || process.env.HOME + "/.xum"
port     = argv.port   || 33999
localip  = argv.local  || '6.66.0.1'
remoteip = argv.remote || '6.66.0.2'
pref     = new Storable HOME + '/config.json', defaults : hostname : null, ssl : {}
links = {}; dist = []; last = 0

log = (key, args...) -> console.log.apply null, ['[',key,']'].concat args
loc = (key, args...) -> console.log.apply null, ['['+'client'.green+'|'+key+']'].concat args
lor = (key, args...) -> console.log.apply null, ['['+'server'.red+  '|'+key+']'].concat args

query = (msg, callback) ->
  socket = net.connect port + 1, (err) -> unless err
    socket.write JSON.stringify msg
    socket.setEncoding 'utf8'
    socket.on 'data', callback if callback?

xum = # don't see a reason for a class here
  init : ->
    generate = no
    ssl = new ync.Sync
      run : no
      read : -> pref.read ssl.proceed
      hostname : -> script 'hostname', (s,h) -> hostname = pref.hostname = h.trim(); ssl.proceed()
      generate_key : -> if pref.ssl.key? then ssl.proceed() else
        log 'ssl'.blue, 'Generating ssl key:'.red, HOME.yellow
        generate = yes
        script """
          mkdir -p $HOME/.xum && cd $HOME/.xum  || exit 1 
          openssl genrsa -out #{HOME}/server-key.pem 4096
          openssl req -new -x509 -subj "/C=XX/ST=xum/L=api/O=IT/CN=#{hostname}" -key #{HOME}/server-key.pem -out #{HOME}/server-cert.pem
        """, (status,err) ->
          pref.ssl.key = fs.readFileSync HOME + "/server-key.pem", 'utf8'
          pref.ssl.cert = fs.readFileSync HOME + "/server-cert.pem", 'utf8'
          pref.save()
          ssl.proceed()
      cleanup : -> script """
          rm #{HOME}/server-key.pem
          rm #{HOME}/server-cert.pem
        """, @proceed
      done : -> log 'ssl'.blue, 'DONE'.green if generate
    ssl.run()

  smartadd : (dev,gw,callback) ->
    n = {}
    n.dev = dev
    n.gw  = gw
    s = new ync.Sync
      getip : -> xl.devip dev, @proceed
      setip : (ip) -> @proceed n.ip = ip
      getmask : -> xl.devmask dev, @proceed
      setmask : (mask) -> @proceed n.mask = mask
      findgw : ->
        if n.gw? and n.gw isnt '' then @proceed()
        else xl.devgw n.dev, @proceed
      foundgw : (gw) ->
        n.gw = gw
        n.gw = xl.netfirst n.ip unless n.gw?
        query add : n, (result) -> callback() if callback?

  add : (net) ->
    net.num = (Object.keys links).length + 1
    loc 'ctl'.magenta, "Adding link #{net.num} #{net.dev} via #{net.gw}"
    net.udp = udp = dgram.createSocket 'udp4'
    udp.on "error", (err) ->
      loc "mux".magenta, "prx error:\n" + err.stack
      udp.close()
    udp.on "listening",=>
      loc "mux".magenta, "prx[#{net.num}] bound " + (33890 + net.num).toString().blue
      links[net.dev] = net
      dist.push net
      xum.rebuild()
      loc 'ctl'.magenta, "Added link #{net.num} #{net.dev} via #{net.gw}"
    udp.bind port


  rebuild : -> # console.log "rebuilding".red
    s = """
      iptables -F INPUT; iptables -F OUTPUT
      iptables -A INPUT -m state --state ESTABLISHED,RELATED -j CONNMARK --restore-mark
      iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j CONNMARK --restore-mark\n"""
    s += """
      grep -q "^10#{l.num}" /etc/iproute2/rt_tables || echo "10#{l.num} T#{l.dev}" >> /etc/iproute2/rt_tables
      ip route flush table T#{l.dev}
      ip route show table main | grep -Ev '(^default)' | grep #{l.dev} | while read ROUTE ; do
        ip route add table T#{l.dev} $ROUTE; done
      ip route add table T#{l.dev} #{l.gw} dev #{l.dev} src #{l.ip}
      ip route add table T#{l.dev} default via #{l.gw}
      ip rule add from #{l.gw} lookup T#{l.dev}
      ip rule add fwmark #{l.num} lookup T#{l.dev}
      iptables -A INPUT -i #{l.dev} -m state --state NEW -j CONNMARK --set-mark #{l.num}
      iptables -A INPUT -m connmark --mark #{l.num} -j MARK --set-mark #{l.num}
      iptables -A INPUT -p udp --sport #{33980 + l.num} -j CONNMARK --set-mark #{l.num}\n
    """ for k,l of links
    s += """iptables -A INPUT -m state --state NEW -m connmark ! --mark 0 -j CONNMARK --save-mark"""
    # console.log 'echo '+i+'\n'+i for i in s.split '\n'
    script s

  connect : ->
    address = args.shift(); ssh = vpn = null
    [ user, address ] = address.split(/@/) if address.match /@/
    [ address, sshport ] = address.split(/:/) if address.match /:/
    user = process.env.USER unless user?
    sshport = 22 unless sshport?
    loc 'connect'.yellow, 'to', user.blue+'@'+address.cyan+':'+sshport.toString().magenta, '[', path.black, ']'
    connect = new ync.Sync
      read : -> pref.read @proceed
      ssh : -> scriptline """
        cat #{path} | ssh -Tp #{sshport} #{user}@#{address} '
        echo "xum bootstrap $HOME/.xum/xum"
        mkdir -p $HOME/.xum && cd $HOME/.xum || exit 1 
        cat - > ./xum
        echo "xum check $(md5sum ./xum)"
        coffee ./xum deps || {
          echo "xum deps install"
          npm install optimist colors portfinder ync storable xumlib 2>&1
          echo "xum deps installed" ; }
        test -f config.json || {
          echo "xum init"
          coffee ./xum init; }
        echo "xum start mux"
        coffee ./xum server 33999 &
        read; exit 0'""",
          error : (line) -> log 'ssh'.red, line.trim() unless line is ''
          line : (line) ->
            if line.match /xum /
              line = line.split(/\ /); line.shift()
              status = line.shift()
              switch status
                when 'pid'
                  pref.remote = pid : line.shift(), port : null
                when 'port'
                  pref.remote.port = line.shift()
                  pref.save()
                when 'ready'
                  loc 'server'.blue, 'ready'.green
                  connect.proceed()
                else loc 'ssh'.blue, status.red, line
            else if line isnt '' then lor 'debug'.black, line
            null
      ctl : ->
        server = net.createServer (socket) ->
          addr = socket.remoteAddress
          loc 'ctl'.magenta, 'connected'.green, addr
          socket.setEncoding 'utf8'
          socket.on 'end',  -> loc 'ctl'.magenta, 'disconnected'.green, addr
          socket.on 'data', (data) -> for k,v of data = JSON.parse data
            switch k
              when 'add' then xum.add v
              when 'del'
                delete dist[l] for l,w in dist when w.dev is v.dev 
                delete links[v] if links[v]?
                xum.rebuild()
              when 'list' then socket.write JSON.stringify links          
        server.listen port + 1, '127.0.0.1', => @proceed loc 'ctl'.magenta, 'listening on port', port + 1
      get_default_gw : -> xl.gwdev @proceed
      add_default_gw : (gw, dev) -> @proceed xum.smartadd(dev, gw)
      mux : ->
        udp = dgram.createSocket 'udp4'
        udp.on "error", (err) ->
          loc "mux".magenta, "prx error:\n" + err.stack
          udp.close()
        udp.on "message", xum.dist udp, port - 1
        udp.on "listening",=>
          address = udp.address()
          loc "mux".magenta, "prx listening " + address.address + ":" + address.port
          connect.proceed console.log 'mux'.magenta, 'listening on port', port
        udp.bind port
      vpn : -> scriptline "openvpn --local 127.0.0.1 #{port - 1} --remote 127.0.0.1 #{port} --dev tun --ifconfig #{localip} #{remoteip}",
        error : (line) -> loc 'vpn'.red, line.trim() unless line is ''
        line : (line) -> loc 'vpn'.blue, line.trim() unless line is ''

  dist : (udp,port) -> (msg, rinfo) ->
    if rinfo.address is "127.0.0.1"
      last = last + 1 % dist.length
      link = dist[last]
      console.log "mux prx got: " + msg + " from " + rinfo.address + ":" + rinfo.port + ' using link ' + last
      udp.send msg, 0, msg.length, link.port, link.address
    else udp.send msg, 0, msg.length, port, "127.0.0.1"

  server : ->
    t = localip; localip =  remoteip; remoteip = t
    start = new ync.Sync
      read : -> pref.read @proceed
      kill : -> if pref.pid then script "kill -9 #{pref.pid}", @proceed else @proceed()
      save : ->
        pref.pid  = process.pid
        pref.save @proceed
      mux : ->
        new_link = (rinfo) ->
          port = rinfo.port
          last = port
          links[port] = rinfo
          rinfo.start = rinfo.last = new Date
          dist.push port
        udp = dgram.createSocket 'udp4'
        udp.on "error", (err) ->
          console.log "mux prx error:\n" + err.stack
          udp.close()
        udp.once "message", (msg, rinfo) ->
          console.log 'initial packet from', rinfo.address, rinfo.port
          new_link rinfo
          last = 0
          udp.on "message", xum.dist udp, port
        udp.on "listening", ->
          address = udp.address()
          start.proceed console.log "mux prx listening " + address.address + ":" + address.port
        udp.bind port - 1
      vpn : -> @proceed scriptline """openvpn --local 127.0.0.1 --port #{port} --dev tun --ifconfig #{localip} #{remoteip}""",
        error : (s) -> console.log 'vpn'.magenta, s.red   unless s is ''
        line  : (s) -> console.log 'vpn'.magenta, s.black unless s is ''
      done : ->
        console.log 'xum pid',  process.pid
        console.log 'xum port', port-1, port
        console.log 'xum ready'

  cli : (cmd) -> switch cmd
    when 'deps' then process.exit 0
    when 'init' then xum.init()
    when 'list' then query list : yes, (data) -> console.log JSON.parse data
    when 'add' then xum.smartadd args.shift(),args.shift()
    when 'connect' then xum.connect()
    when 'server'  then xum.server()
    else console.log 'error'.red, 'Command', cmd.red, 'not found.'

module.exports = xum
xum.cli args.shift()
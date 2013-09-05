"""
"""
from mininet.log import info, error, debug
from mininet.util import makeIntfPair, quietRun
from mininet.net import Mininet
import re

class RestfulSevice( object ):

    "RESTful service for mininet api"

    def __init__( self, net, httpport=8080):
        """name: interface name (e.g. h1-eth0)
           node: owning node (where this intf most likely lives)
           link: parent link if we're part of a link
           other arguments are passed to config()"""
        self.port=httpport
        self.net = net 

    def start( self ):
        print "Starting RESTful service at port %d" %self.port
        self.status = 'running'
    def stop(self):
        print "Stopping RESTful service"
        self.status = 'stopped'
         
    def __repr__( self ):
        return '<%s %s>' % ( self.__class__.__name__, self.port )

    def __str__( self ):
        return self.name

 

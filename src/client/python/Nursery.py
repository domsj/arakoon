"""
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
"""

from Arakoon import ArakoonClient 
from NurseryRouting import RoutingInfo 
from ArakoonExceptions import NurseryRangeError
from functools import wraps
import time

maxDuration = 60

def retryDuringMigration (f):
    @wraps(f)    
    def retrying_f (self,*args,**kwargs):
        naptime = 0.1
        duration = 0.0
        start = time.time()
        
        callSucceeded = False
        while (not callSucceeded and duration < maxDuration ):
            try:
                retVal = f(self,*args,**kwargs)
                callSucceeded = True
            except (NurseryRangeError):
                logging.warning("Nursery range error. Sleep %f before next attempt" % naptime)
                time.sleep(naptime)       
                duration = time.time() - start
                naptime *= 1.5    
                self._fetchNurseryConfig()
        return retVal
    
    return retrying_f

class NurseryClient:
    
    def __init__(self,clientConfig):
        self.nurseryClusterId = clientConfig.getClusterId()
        self._nurseryClient = ArakoonClient(clientConfig)
        self._fetchNurseryConfig()
    
    def _fetchNurseryConfig(self):
        (routing,cfgs) = self._nurseryClient.getNurseryConfig()
        self._routing = routing
        
        for (clusterId,client) in self._clusterClients :
            client._dropConnections()
        
        self._clusterClients = dict()
        for (clusterId,cfg) in cfgs.iteritems():
            client = ArakoonClient(cfg)
            self._clusterClients[clusterId] = client
    
    def _getArakoonClient(self, key):
        clusterId = self._routing.getClusterId(key)
        return self._clusterClients[clusterId]
    
    @retryDuringMigration
    def set(self, key, value):
        client = self._getArakoonClient(key)
        client.set(key,value)
        
    @retryDuringMigration
    def get(self, key):
        client = self._getArakoonClient(key)
        return client.get(key)
    
    @retryDuringMigration
    def delete(self, key):
        client = self._getArakoonClient(key)
        client.delete(key)

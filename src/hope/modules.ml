open Bstore
open Mp_driver

module BADispatcher = Dispatcher.ADispatcher(BStore)
module FSMDriver = MPDriver(BADispatcher)

module DISPATCHER = BADispatcher
module DRIVER = FSMDriver



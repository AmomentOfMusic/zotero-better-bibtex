declare const Zotero: any

import EventEmitter = require('eventemitter4')

import { debug } from './debug.ts'
import { patch as $patch$ } from './monkey-patch.ts'

// export singleton: https://k94n.com/es6-modules-single-instance-pattern
export let Events = new EventEmitter() // tslint:disable-line:variable-name

if (Zotero.Debug.enabled) {
  const events = [
    'preference-changed',
    'items-changed',
    'items-removed',
    'libraries-changed',
    'collections-changed',
    'collections-removed',
    'libraries-removed',
    'loaded',
  ]

  $patch$(Events, 'on', original => function() {
    if (!events.includes(arguments[0])) throw new Error(`Unsupported event ${arguments[0]}`)
    debug('events: handler registered for', arguments[0])
    original.apply(this, arguments)
  })

  $patch$(Events, 'emit', original => function() {
    if (!events.includes(arguments[0])) throw new Error(`Unsupported event ${arguments[0]}`)
    debug('events: emitted', Array.prototype.slice.call(arguments))
    original.apply(this, arguments)
  })

  for (const event of events) {
    (e => Events.on(e, () => debug(`events: got ${e}`)))(event)
  }
}

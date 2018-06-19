const jQuery = require('jquery')
const _ = require('lodash')
const autosize = require('textarea-autosize')
const Mousetrap = require('mousetrap')

const fs = require('fs')
const path = require('path')
import { execFile } from 'child_process'
const {promisify} = require('util')
const {ipcRenderer, remote, webFrame, shell} = require('electron')
const {app, dialog} = remote
const querystring = require('querystring')
const Store = require('electron-store')

import PouchDB from "pouchdb";

const sha1 = require('sha1')
const machineIdSync = require('node-machine-id').machineIdSync

const React = require('react')
const ReactDOM = require('react-dom')
const CommitsGraph = require('react-commits-graph')
const io = require('socket.io-client')

const dbMapping = require('./db-mapping')
const fio = require('./file-io')
const shared = require('./shared')
const errorAlert = shared.errorAlert
window.Elm = require('../elm/Main')



/* === Global Variables === */

const userStore = new Store({name: "config"})
var lastActivesScrolled = null
var lastColumnScrolled = null
var collab = {}
self.savedObjectIds = [];

var firstRun = userStore.get('first-run', true)
var appWindow = remote.getCurrentWindow()
var dbName = appWindow.dbName;
var jsonImportData = appWindow.jsonImportData;



const mock = require('../../test/mocks.js')
if(process.env.RUNNING_IN_SPECTRON) {
  mock(dialog
      , process.env.DIALOG_CHOICE
      , process.env.DIALOG_SAVE_PATH
      , [process.env.DIALOG_OPEN_PATH]
      )
}



/* === Initializing App === */

console.log('Gingko version', app.getVersion())

document.title = `${(!!appWindow.docName) ? appWindow.docName : "Untitled"} - Gingko`

var dbpath = path.join(app.getPath('userData'), dbName)
self.db = new PouchDB(dbpath)

if(!!jsonImportData) {
  var initFlags =
    [ jsonImportData
      , { isMac : process.platform === "darwin"
        , shortcutTrayOpen : userStore.get('shortcut-tray-is-open', true)
        , videoModalOpen : userStore.get('video-modal-is-open', false)
      }
    ]
  self.gingko = Elm.Main.fullscreen(initFlags)

  gingko.ports.infoForOutside.subscribe(function(elmdata) {
    update(elmdata.tag, elmdata.data)
  })
} else {
  load().then(function (dbData) {

    savedObjectIds = Object.keys(dbData[1].commits).concat(Object.keys(dbData[1].treeObjects))

    var initFlags =
      [ dbData
        , { isMac : process.platform === "darwin"
          , shortcutTrayOpen : userStore.get('shortcut-tray-is-open', true)
          , videoModalOpen : userStore.get('video-modal-is-open', false)
        }
      ]
    self.gingko = Elm.Main.fullscreen(initFlags)

    gingko.ports.infoForOutside.subscribe(function(elmdata) {
      update(elmdata.tag, elmdata.data)
    })
  })
}


self.socket = io.connect('http://localhost:3000')


window.onbeforeunload = (e) => {
  toElm('IntentExit', null)
  e.returnValue = false
}

var toElm = function(tag, data) {
  gingko.ports.infoForElm.send({tag: tag, data: data})
}

//self.remoteCouch = 'http://localhost:5984/atreenodes16'
//self.remoteDb = new PouchDB(remoteCouch)

var crisp_loaded = false;

// Needed for unit tests
window.$crisp = (typeof $crisp === 'undefined') ? [] : $crisp

$crisp.push(['do', 'chat:hide'])
$crisp.push(['on', 'session:loaded', () => { crisp_loaded = true }])
$crisp.push(['on', 'chat:closed', () => { $crisp.push(['do', 'chat:hide']) }])
$crisp.push(['on', 'chat:opened', () => { $crisp.push(['do', 'chat:show']) }])
$crisp.push(['on', 'message:received', () => { $crisp.push(['do', 'chat:show']) }])
if (firstRun) {
  var ctrlOrCmd = process.platform === "darwin" ? "⌘" : "Ctrl";
  userStore.set('first-run', false)
  $crisp.push(['do'
              , 'message:show'
              , [ 'text' ,
`Hi! Try these steps to get started:
1. **Enter** to start writing
2. **${ctrlOrCmd} + Enter** to save changes
3. **${ctrlOrCmd} + →** to write in a new *child* card
4. **${ctrlOrCmd} + Enter** to save changes
5. **${ctrlOrCmd} + ↓**

I know it's not much guidance, but it's a start.
**Help > Contact Adriano** to send me a message.

---
*PS: I won't interrupt again, except to respond.*
*Your attention is sacred.*`
                ]
              ]
             )
}


/* === Elm to JS Ports === */

const update = (msg, data) => {
  let cases =
    {
      // === Dialogs, Menus, Window State ===

      'Alert': () => { alert(data) }

    , 'SaveAndClose': async () => {
        if (!!data) {
           try {
             await saveToDB(data[0], data[1])
           } catch (e) {
             dialog.showMessageBox(saveErrorAlert(e))
             return;
           }
        }

        if (!!appWindow.docName) {
          // has Title, so close
          appWindow.destroy();

          // here is the double-quit bug... when asked to quit, that calls "beforeunload" which calls
          // "IntentExit" which calls this function.
          // Need to, instead, send a message to app.js saying "close this window, and quit if it's the last one"?
          // No, because that doesn't keep the distinction between "close all windows" and "quit" that macOS needs
        } else {
          // is Untitled, so ask user to rename
          ipcRenderer.send('app:rename-untitled', dbName, null, true)
        }
      }

    , 'ConfirmCancelCard': () => {
        let tarea = document.getElementById('card-edit-'+data[0])

        if (tarea === null) {
          console.log('tarea not found')
        } else {
          if(tarea.value === data[1]) {
            toElm('CancelCardConfirmed', null)
          } else if (confirm('Are you sure you want to cancel your changes?')) {
            toElm('CancelCardConfirmed', null)
          }
        }
      }

    , 'ColumnNumberChange': () => {
        ipcRenderer.send('column-number-change', data)
      }

      // === Database ===

    , 'SaveToDB': async () => {
        document.title = document.title.startsWith('*') ? document.title : '*' + document.title
        try {
          var newHeadRev = await saveToDB(data[0], data[1])
        } catch (e) {
          dialog.showMessageBox(saveErrorAlert(e))
          return;
        }
        toElm('SetHeadRev', newHeadRev)
        document.title = document.title.replace(/^\*/, "")
      }

    , 'Push': push

    , 'Pull': sync

      // === File System ===

    , 'ExportDOCX': () => {
        try {
          exportDocx(data)
        } catch (e) {
          dialog.showMessageBox(errorAlert('Export Error', "Couldn't export.\nTry again.", e))
          return;
        }
      }

    , 'ExportJSON': () => {
        try {
          exportJson(data)
        } catch (e) {
          dialog.showMessageBox(errorAlert('Export Error', "Couldn't export.\nTry again.", e))
          return;
        }
      }

    , 'ExportTXT': () => {
        try {
          exportTxt(data)
        } catch (e) {
          dialog.showMessageBox(errorAlert('Export Error', "Couldn't export.\nTry again.", e))
          return;
        }
      }

    , 'ExportTXTColumn': () => {
        try {
          exportTxt(data)
        } catch (e) {
          dialog.showMessageBox(errorAlert('Export Error', "Couldn't export.\nTry again.", e))
          return;
        }
      }

      // === DOM ===

    , 'ActivateCards': () => {
        lastActivesScrolled = data.lastActives
        lastColumnScrolled = data.column

        setLastActive(data.filepath, data.cardId)
        shared.scrollHorizontal(data.column)
        shared.scrollColumns(data.lastActives)
      }

    , 'FlashCurrentSubtree': () => {
        let addFlashClass = function() {
          jQuery('.card.active').addClass('flash')
          jQuery('.group.active-descendant').addClass('flash')
        }

        let removeFlashClass = function() {
          jQuery('.card.active').removeClass('flash')
          jQuery('.group.active-descendant').removeClass('flash')
        }

        addFlashClass()
        setTimeout(removeFlashClass, 200)
      }

    , 'TextSurround': () => {
        let id = data[0]
        let surroundString = data[1]
        let tarea = document.getElementById('card-edit-'+id)

        if (tarea === null) {
          console.log('Textarea not found for TextSurround command.')
        } else {
          let start = tarea.selectionStart
          let end = tarea.selectionEnd
          if (start !== end) {
            let text = tarea.value.slice(start, end)
            let modifiedText = surroundString + text + surroundString
            document.execCommand('insertText', true, modifiedText)
          }
        }
      }

      // === UI ===

    , 'UpdateCommits': () => {
        let commitGraphData = _.sortBy(data[0].commits, 'timestamp').reverse().map(c => { return {sha: c._id, parents: c.parents}})
        let selectedSha = data[1]

        let commitElement = React.createElement(CommitsGraph, {
          commits: commitGraphData,
          onClick: setHead,
          selected: selectedSha
        });

        //ReactDOM.render(commitElement, document.getElementById('history'))
    }
    , 'SetVideoModal': () => {
        userStore.set('video-modal-is-open', data)
      }

    , 'SetShortcutTray': () => {
        userStore.set('shortcut-tray-is-open', data)
      }

      // === Misc ===

    , 'SocketSend': () => {
        collab = data
        socket.emit('collab', data)
      }

    , 'ConsoleLogRequested': () =>
        console.log(data)

    }

  try {
    cases[msg]()
  } catch(err) {
    console.log('elmCases one-port failed:', err, msg, data)
  }
}






/* === JS to Elm Ports === */

ipcRenderer.on('menu-new', () => toElm('IntentNew', null))
ipcRenderer.on('menu-open', () => toElm('IntentOpen', null ))
ipcRenderer.on('menu-import-json', () => toElm('IntentImport', null))
ipcRenderer.on('menu-save', () => toElm('IntentSave', null ))
ipcRenderer.on('menu-save-as', () => toElm('IntentSaveAs', null))
ipcRenderer.on('menu-export-docx', () => toElm('IntentExport', { format : "docx", selection: "all" }))
ipcRenderer.on('menu-export-docx-current', () => toElm('IntentExport', { format : "docx", selection: "current" }))
ipcRenderer.on('menu-export-docx-column', (e, msg) => toElm('IntentExport', { format : "docx", selection: { column: msg } }))
ipcRenderer.on('menu-export-txt', () => toElm('IntentExport', { format : "txt", selection: "all" }))
ipcRenderer.on('menu-export-txt-current', () => toElm('IntentExport', { format : "txt", selection: "current" }))
ipcRenderer.on('menu-export-txt-column', (e, msg) => toElm('IntentExport', { format : "txt", selection: { column: msg } }))
ipcRenderer.on('menu-export-json', () => toElm('IntentExport', { format : "json", selection: "all" }))
ipcRenderer.on('menu-cut', (e, msg) => toElm('Keyboard', ["mod+x", Date.now()]))
ipcRenderer.on('menu-copy', (e, msg) => toElm('Keyboard', ["mod+c", Date.now()]))
ipcRenderer.on('menu-paste', (e, msg) => toElm('Keyboard', ["mod+v", Date.now()]))
ipcRenderer.on('menu-paste-into', (e, msg) => toElm('Keyboard', ["mod+shift+v", Date.now()]))
ipcRenderer.on('zoomin', e => { webFrame.setZoomLevel(webFrame.getZoomLevel() + 1) })
ipcRenderer.on('zoomout', e => { webFrame.setZoomLevel(webFrame.getZoomLevel() - 1) })
ipcRenderer.on('resetzoom', e => { webFrame.setZoomLevel(0) })
ipcRenderer.on('menu-view-videos', () => toElm('ViewVideos', null ))
ipcRenderer.on('menu-contact-support', () => { if(crisp_loaded) { $crisp.push(['do', 'chat:open']); $crisp.push(['do', 'chat:show']); } else { shell.openExternal('mailto:adriano@gingkoapp.com') } } )
ipcRenderer.on('main:delete-and-close', async () => { await db.destroy(); await dbMapping.removeDb(dbName); appWindow.destroy(); })

socket.on('collab', data => toElm('RecvCollabState', data))
socket.on('collab-leave', data => toElm('CollaboratorDisconnected', data))






/* === Database === */

const processData = function (data, type) {
  var processed = data.filter(d => d.type === type).map(d => _.omit(d, 'type'))
  var dict = {}
  if (type == "ref") {
    processed.map(d => dict[d._id] = _.omit(d, '_id'))
  } else {
    processed.map(d => dict[d._id] = _.omit(d, ['_id','_rev']))
  }
  return dict
}


function load(filepath, headOverride){
  return new Promise( (resolve, reject) => {
    db.info().then(function (result) {
      if (result.doc_count == 0) {
        let toSend = [{_id: 'status' , status : 'bare', bare: true}, { commits: {}, treeObjects: {}, refs: {}}];
        resolve(toSend)
      } else {

        db.get('status')
          .catch(err => {
            if(err.name == "not_found") {
              console.log('load status not found. Setting to "bare".')
              return {_id: 'status' , status : 'bare', bare: true}
            } else {
              reject('load status error' + err)
            }
          })
          .then(statusDoc => {
            status = statusDoc.status;

            db.allDocs(
              { include_docs: true
              }).then(function (result) {
              let data = result.rows.map(r => r.doc)

              let commits = processData(data, "commit");
              let trees = processData(data, "tree");
              let refs = processData(data, "ref");
              let status = _.omit(statusDoc, '_rev')

              if(headOverride) {
                refs['heads/master'] = headOverride
              } else if (_.isEmpty(refs)) {
                var keysSorted = Object.keys(commits).sort(function(a,b) { return commits[b].timestamp - commits[a].timestamp })
                var lastCommit = keysSorted[0]
                if (!!lastCommit) {
                  refs['heads/master'] = { value: lastCommit, ancestors: [], _rev: "" }
                  console.log('recovered status', status)
                  console.log('refs recovered', refs)
                }
              }

              let toSend = [status, { commits: commits, treeObjects: trees, refs: refs}];
              resolve(toSend)
            }).catch(function (err) {
              dialog.showMessageBox(errorAlert("Loading Error", "Couldn't load file.", err))
              reject(err)
            })
        })
      }
    })
  })
}

const merge = function(local, remote){
  db.allDocs( { include_docs: true })
    .then(function (result) {
      data = result.rows.map(r => r.doc)

      let commits = processData(data, "commit");
      let trees = processData(data, "tree");
      let refs = processData(data, "ref");

      let toSend = { commits: commits, treeObjects: trees, refs: refs};
      toElm('Merge', [local, remote, toSend]);
    }).catch(function (err) {
      console.log(err)
    })
}


const pull = function (local, remote, info) {
  db.replicate.from(remoteCouch)
    .on('complete', pullInfo => {
      if(pullInfo.docs_written > 0 && pullInfo.ok) {
        merge(local, remote)
      }
    })
}


const push = function () {
  db.replicate.to(remoteCouch)
}


const sync = function () {
  db.get('heads/master')
    .then(localHead => {
      remoteDb.get('heads/master')
        .then(remoteHead => {
          if(_.isEqual(localHead, remoteHead)) {
            // Local == Remote => no changes
            console.log('up-to-date')
          } else if (localHead.ancestors.includes(remoteHead.value)) {
            // Local is ahead of remote => Push
            push('push:Local ahead of remote')
          } else {
            // Local is behind of remote => Pull
            pull(localHead.value, remoteHead.value, 'Local behind remote => Fetch & Merge')
          }
        })
        .catch(remoteHeadErr => {
          if(remoteHeadErr.name == 'not_found') {
            // Bare remote repository => Push
            push('push:bare-remote')
          }
        })
    })
    .catch(localHeadErr => {
      remoteDb.get('heads/master')
        .then(remoteHead => {
          if(localHeadErr.name == 'not_found') {
            // Bare local repository => Pull
            pull(null, remoteHead.value, 'Bare local => Fetch & Merge')
          }
        })
        .catch(remoteHeadErr => {
          if(remoteHeadErr.name == 'not_found') {
            // Bare local & remote => up-to-date
            push('up-to-date (bare)')
          }
        })
    })
}


const setHead = function(sha) {
  if (sha) {
    toElm('CheckoutCommit', sha)
  }
}




/* === Local Functions === */

self.saveToDB = (status, objects) => {
  return new Promise(
    async (resolve, reject) => {
      try {
        var statusDoc =
          await db.get('status')
                .catch(err => {
                  if(err.name == "not_found") {
                    return {_id: 'status' , status : 'bare', bare: true}
                  } else {
                    console.log('load status error', err)
                  }
                })
      } catch (e) {
        reject(e)
        return;
      }

      if(statusDoc._rev) {
        status['_rev'] = statusDoc._rev
      }


      // Filter out object that are already saved in database
      objects.commits = objects.commits.filter( o => !savedObjectIds.includes(o._id))
      objects.treeObjects = objects.treeObjects.filter( o => !savedObjectIds.includes(o._id))

      let toSave = objects.commits.concat(objects.treeObjects).concat(objects.refs).concat([status]);

      try {
        var responses = await db.bulkDocs(toSave)
        let savedIds = responses.filter(r => r.ok && r.id !== "status" && r.id !== "heads/master")
        savedObjectIds = savedObjectIds.concat(savedIds.map( o => o.id))
      } catch (e) {
        reject(e)
        return;
      }

      let head = responses.filter(r => r.id == "heads/master")[0]
      if (head.ok) {
        dbMapping.setModified(dbName)
        resolve(head.rev)
      } else {
        reject(new Error('Reference error when saving to DB.'))
        return;
      }
    })
}


self.save = (filepath) => {
  return new Promise(
    async (resolve, reject) => {
      try {
        let saveResult = await fio.save(db, filepath)

        document.title = `${path.basename(filepath)} - Gingko`
        toElm('FileState', [filepath, false])
        resolve(true)
      } catch(err) {
        dialog.showMessageBox(saveErrorAlert(err))
      }
    }
  )
}


const saveErrorAlert = (err) => {
  return errorAlert("Save Error", "The file wasn't saved.\nPlease try again.", err)
}


const exportDocx = (data, defaultPath) => {
  if (data && typeof data.replace === 'function') {
    data = (process.platform === "win32") ? data.replace(/\n/g, '\r\n') : data;
  } else {
    throw new Error('invalid data sent for export')
  }

  var options =
    { title: 'Export to MS Word'
    , defaultPath: defaultPath ? defaultPath.replace('.gko', '') : path.join(app.getPath('documents'),"Untitled.docx")
    , filters:  [ {name: 'Word Files', extensions: ['docx']}
                , {name: 'All Files', extensions: ['*']}
                ]
    }

  dialog.showSaveDialog(options, function(filepath){
    if(typeof filepath == "string"){
      let tmpMarkdown = path.join(app.getPath('temp'), path.basename(filepath) + ".md")

      fs.writeFile(tmpMarkdown, data, (err) => {
        if (err) throw new Error('export-docx writeFile failed')

        let pandocPath = path.join(__dirname, '/../../pandoc')

        // pandoc file is copied by electron-builder
        // so we need to point to the src directory when running with `yarn electron`
        if (process.env.RUNNING_LOCALLY) {
          switch (process.platform) {
            case 'linux':
              pandocPath = path.join(__dirname, '/../../src/bin/linux/pandoc')
              break;

            case 'win32':
              pandocPath = path.join(__dirname, '/../../src/bin/win/pandoc.exe')
              break;

            case 'darwin':
              pandocPath = path.join(__dirname, '/../../src/bin/mac/pandoc')
              break;
          }
        }

        execFile( pandocPath
          , [ tmpMarkdown
            , '--from=gfm'
            , '--to=docx'
            , `--output=${filepath}`
            , '--verbose'
            ]
          , ( err, stdout, stderr) => {
              if (err) {
                throw err;
              }

              fs.unlink(tmpMarkdown, (err) => {
                if (err) {
                  throw err
                }

                shell.openItem(filepath)
              })
          })
      })
    }
  })
}


const exportJson = (data, defaultPath) => {
  return new Promise(
    (resolve, reject) => {
      var options =
        { title: 'Export JSON'
        , defaultPath: defaultPath ? defaultPath.replace('.gko', '') : path.join(app.getPath('documents'),"Untitled.json")
        , filters:  [ {name: 'Gingko JSON (*.json)', extensions: ['json']}
                    , {name: 'All Files', extensions: ['*']}
                    ]
        }

      dialog.showSaveDialog(options, function(filepath){
        if(!!filepath){
          fs.writeFile(filepath, JSON.stringify(data, undefined, 2), (err) => {
            if (err) {
              reject(new Error('export-json writeFile failed'))
              return;
            }
            resolve(data)
          })
        } else {
          reject(new Error('no export path chosen'))
          return;
        }
      })
    }
  )
}

const exportTxt = (data, defaultPath) => {
  return new Promise(
    (resolve, reject) => {
      if (data && typeof data.replace === 'function') {
        data = (process.platform === "win32") ? data.replace(/\n/g, '\r\n') : data;
      } else {
        reject(new Error('invalid data sent for export'))
        return;
      }

      var options =
        { title: 'Export TXT'
        , defaultPath: defaultPath ? defaultPath.replace('.gko', '') : path.join(app.getPath('documents'),"Untitled.txt")
        , filters:  [ {name: 'Text File', extensions: ['txt']}
                    , {name: 'All Files', extensions: ['*']}
                    ]
        }

      dialog.showSaveDialog(options, function(filepath){
        if(!!filepath){
          fs.writeFile(filepath, data, (err) => {
            if (err) {
              reject(new Error('export-txt writeFile failed'))
              return;
            }
            resolve(data)
          })
        } else {
          reject(new Error('no export path chosen'))
          return;
        }
      })
    }
  )
}


function setLastActive (filepath, lastActiveCard) {
  if (filepath !== null) {
    userStore.set(`last-active-cards.${filepath}`, lastActiveCard);
  }
}


function getLastActive (filepath) {
  let lastActiveCard = userStore.get(`last-active-cards.${filepath}`)
  if (typeof lastActiveCard === "undefined") {
    return null
  } else {
    return lastActiveCard
  }
}




/* === DOM Events and Handlers === */

// Prevent default events, for file dragging.
document.ondragover = document.ondrop = (ev) => {
  ev.preventDefault()
}

window.onresize = () => {
  if (lastActivesScrolled) {
    debouncedScrollColumns(lastActivesScrolled)
  }
  if (lastColumnScrolled) {
    debouncedScrollHorizontal(lastColumnScrolled)
  }
}

const debouncedScrollColumns = _.debounce(shared.scrollColumns, 200)
const debouncedScrollHorizontal = _.debounce(shared.scrollHorizontal, 200)


const editingInputHandler = function(ev) {
  toElm('FieldChanged', ev.target.value)
  document.title = document.title.startsWith('*') ? document.title : '*' + document.title
  collab.field = ev.target.value
  socket.emit('collab', collab)
}



Mousetrap.bind(shared.shortcuts, function(e, s) {
  toElm('Keyboard',[s,Date.now()]);

  if(shared.needOverride.includes(s)) {
    return false;
  }
});


Mousetrap.bind(['tab'], function(e, s) {
  document.execCommand('insertText', false, '  ')
  return false;
});

Mousetrap.bind(['shift+tab'], function(e, s) {
  return true;
});


/* === DOM manipulation === */


document.addEventListener('click', (ev) => {
  if(ev.target.nodeName == "A") {
    ev.preventDefault()
    shell.openExternal(ev.target.href)
  }
})


const observer = new MutationObserver(function(mutations) {
  let isTextarea = function(node) {
    return node.nodeName == "TEXTAREA" && node.className == "edit mousetrap"
  }

  let textareas = [];

  mutations
    .map( m => {
          [].slice.call(m.addedNodes)
            .map(n => {
              if (isTextarea(n)) {
                textareas.push(n)
              } else {
                if(n.querySelectorAll) {
                  let tareas = [].slice.call(n.querySelectorAll('textarea.edit'))
                  textareas = textareas.concat(tareas)
                }
              }
            })
        })

  if (textareas.length !== 0) {
    textareas.map(t => {
      t.oninput = editingInputHandler;
    })
    ipcRenderer.send('edit-mode-toggle', true)
    jQuery(textareas).textareaAutoSize()
  } else {
    ipcRenderer.send('edit-mode-toggle', false)
  }
});

const config = { childList: true, subtree: true };

observer.observe(document.body, config);

//= require <prototype>
//= require <effects>
//= require <dragdrop>
//= require <shortcut>

var Alice = { };

//= require <alice/util>
//= require <alice/application>
//= require <alice/connection>
//= require <alice/window>
//= require <alice/input>
//= require <alice/keyboard>
//= require <alice/completion>

var alice = new Alice.Application();

document.observe("dom:loaded", function () {
  $$("div.topic").each(function (topic){
    topic.innerHTML = Alice.makeLinksClickable(topic.innerHTML)});
  $('config_button').observe("click", alice.toggleConfig.bind(alice));
  alice.activeWindow().input.focus()
  window.onkeydown = function (e) {
    if (!$('config') && !Alice.isSpecialKey(e.which))
      alice.activeWindow().input.focus()};
  window.onresize = function () {
    alice.activeWindow().scrollToBottom()};
  window.status = " ";  
  window.onfocus = function () {
    alice.activeWindow().input.focus();
    alice.isFocused = true};
  window.onblur = function () {alice.isFocused = false};
  Alice.makeSortable();
  if (Prototype.Browser.MobileSafari) {
    setTimeout(function(){window.scrollTo(0,1)}, 5000);
    $$('button').invoke('setStyle',
      {display:'block',position:'absolute',right:'0px'});
  }
});

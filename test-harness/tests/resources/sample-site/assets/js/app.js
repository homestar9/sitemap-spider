document.addEventListener('DOMContentLoaded', function() {
  var jsLinks = document.getElementById('js-links');
  var link = document.createElement('a');
  link.href = 'js-link.cfm';
  link.textContent = 'JS Injected link';
  jsLinks.appendChild(link);

  setTimeout(function(){
    var lateLink = document.createElement('a');
    lateLink.href = 'js-link-late.cfm';
    lateLink.textContent = 'Late loaded link';
    jsLinks.appendChild(lateLink);
  }, 3000);
});
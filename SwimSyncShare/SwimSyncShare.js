// Runs inside Safari when a page is shared. Hands the app the readable text
// so a web page can be read aloud without a second fetch.
var SwimSyncShare = function() {};

SwimSyncShare.prototype = {
    run: function(arguments) {
        var text = "";
        try {
            var article = document.querySelector("article, main, [role=main]") || document.body;
            text = article ? article.innerText : "";
        } catch (e) {}
        arguments.completionFunction({
            "title": document.title || "",
            "url": document.URL || "",
            "text": text
        });
    },
    finalize: function(arguments) {}
};

var ExtensionPreprocessingJS = new SwimSyncShare;

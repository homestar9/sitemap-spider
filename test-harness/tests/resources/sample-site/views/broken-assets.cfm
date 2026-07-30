<cfoutput>
    <div class="container">

        <h1>Broken Assets</h1>
        <p>Every asset reference below is missing except the first one.</p>

        <!-- This file exists, so the asset check must not report it. -->
        <img src="./assets/img/sample.jpg" alt="Working image" />

        <!-- These files do not exist. The asset check must report all three.
             The engine returns 500 rather than 404 for a file missing from disk. -->
        <img src="./assets/img/missing.png" alt="Missing image" />
        <link rel="stylesheet" href="./assets/css/missing.css">
        <script src="./assets/js/missing.js"></script>

        <!-- Stands in for an image that returns a real 404. -->
        <img src="./gone-image.cfm" alt="Image that 404s" />

        <!-- A page that returns a real 404. This one is crawled as a page. -->
        <a href="./gone.cfm">Page that 404s</a><br />

        <!-- A direct link to a missing image. notAllowedPattern stops the crawler
             fetching this as a page, so only the asset check can catch it. -->
        <a href="./assets/img/gone.jpg">Missing image link</a><br />

        <!-- A linked PDF that exists. notAllowedPattern does not block .pdf, so
             the crawler fetches this as a page rather than checking it. -->
        <a href="./assets/docs/whitepaper.pdf">Whitepaper</a><br />

    </div>
</cfoutput>

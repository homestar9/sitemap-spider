<cfoutput>
    <div class="container">

        <h1>Broken Assets</h1>
        <p>Every asset reference below is missing except the first one.</p>

        <!-- This file exists, so the asset check must not report it. -->
        <img src="./assets/img/sample.jpg" alt="Working image" />

        <!-- Missing files return 500 here. The asset check must report all three. -->
        <img src="./assets/img/missing.png" alt="Missing image" />
        <link rel="stylesheet" href="./assets/css/missing.css">
        <script src="./assets/js/missing.js"></script>

        <!-- This image returns 404. -->
        <img src="./gone-image.cfm" alt="Image that 404s" />

        <!-- This page returns 404 and is crawled as a page. -->
        <a href="./gone.cfm">Page that 404s</a><br />

        <!-- notAllowedPattern blocks this image, so only the asset check tests it. -->
        <a href="./assets/img/gone.jpg">Missing image link</a><br />

        <!-- notAllowedPattern allows this PDF, so the crawler fetches it as a page. -->
        <a href="./assets/docs/whitepaper.pdf">Whitepaper</a><br />

    </div>
</cfoutput>

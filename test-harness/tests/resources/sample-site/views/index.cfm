<cfoutput>
    <div class="container">
            
        <h1>Welcome to Example Test</h1>
        <p>This page includes static and tricky links.</p>

        <!-- The crawler must resolve this relative image URL. -->
        <img src="./assets/img/sample.jpg" alt="Sample image" />

        <!-- The crawler records this video but does not fetch the missing mp4. -->
        <video src="./assets/video/sample.mp4" poster="./assets/img/sample.jpg"></video>

        <!-- Off-host URL. -->
        <a href="https://www.angrysam.com">Angry Sam Productions</a><br />
        <!-- Duplicate of the navigation link. -->
        <a href="#request.baseHref#about/index.cfm">Visit About (HTTP)</a><br />
        <!-- Non-page links must be skipped. -->
        <a href="mailto:support@example.test">Email us</a><br />
        <a href="tel:+18005551212">Call us</a><br />
        <!-- The parser must report this nofollow link as ignored. -->
        <a href="./nofollow.cfm" rel="nofollow">Sort by price (nofollow)</a><br />
        <!-- The crawler must report this failed request. -->
        <a href="./missing.cfm">Missing Page</a><br />
        <!-- robots.txt blocks this page. -->
        <a href="./disallow.cfm">Disallowed Page</a><br />

        <div id="js-links"></div>

    </div>
</cfoutput>

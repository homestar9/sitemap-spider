<cfoutput>
    <div class="container">
            
        <h1>Welcome to Example Test</h1>
        <p>This page includes static and tricky links.</p>

        <!--- INTENTIONAL: External url --->
        <a href="https://www.angrysam.com">Angry Sam Productions</a><br />
        <!-- INTENTIONAL TRICK: absolute http link (should be detected as duplicate from nav) -->
        <a href="#request.baseHref#about/index.cfm">Visit About (HTTP)</a><br />
        <!-- INTENTIONAL TRICK: mailto -->
        <a href="mailto:support@example.test">Email us</a><br />
        <!-- INTENTIONAL TRICK: tel -->
        <a href="tel:+18005551212">Call us</a><br />
        <!-- INTENTIONAL TRICK: nofollow -->
        <a href="./nofollow.cfm" rel="nofollow">Sort by price (nofollow)</a><br />
        <!-- INTENTIONAL: Missing page -->
        <a href="./missing.cfm">Missing Page</a><br />

        <div id="js-links"></div>

    </div>
</cfoutput>
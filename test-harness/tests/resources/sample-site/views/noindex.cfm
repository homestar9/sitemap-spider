<cfoutput>
    <div class="container">
        <h1>No Index</h1>
        <p>I shouldn't be on the sitemap, but my links should still be followed.</p>
        <!--- noindex-child.cfm is linked from nowhere else, so it only lands on
              the sitemap if this noindex page's links were followed. --->
        <a href="./noindex-child.cfm">Noindex child page</a>
    </div>
</cfoutput>

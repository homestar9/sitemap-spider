<!--- Only the parts that need CFML values are wrapped in cfoutput. The CSS and
      the main script stay outside it, so "##fff" colours and the "##jobsTable"
      selector are not read as CFML expressions. --->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Sitemap Jobs</title>
    <style>
        body { font-family: system-ui, sans-serif; margin: 2rem; color: #222; }
        h1 { margin-bottom: 0.25rem; }
        form.queue { margin: 1rem 0 1.5rem; }
        input[type=url] { width: 24rem; padding: 0.4rem; }
        button { padding: 0.4rem 0.8rem; cursor: pointer; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 0.45rem 0.6rem; text-align: left; font-size: 0.9rem; }
        th { background: #f4f4f4; }
        .status { font-weight: 600; text-transform: capitalize; }
        .status.running { color: #0a58ca; }
        .status.completed { color: #157347; }
        .status.failed { color: #b02a37; }
        .status.canceled, .status.interrupted { color: #8a6d00; }
        .status.queued { color: #555; }
        .muted { color: #888; }
        a.action { margin-right: 0.5rem; }
    </style>
</head>
<body>
    <h1>Sitemap Jobs</h1>
    <p class="muted">Queue a crawl, watch its progress, download the file when it finishes.</p>

    <cfoutput>
    <form class="queue" method="post" action="#event.buildLink( 'jobs.queue' )#">
        <input type="url" name="url" placeholder="https://example.com/" required>
        <label><input type="checkbox" name="runAsync" value="true"> parallel</label>
        <button type="submit">Queue crawl</button>
    </form>
    </cfoutput>

    <table id="jobsTable">
        <thead>
            <tr>
                <th>URL</th>
                <th>Status</th>
                <th>Pages</th>
                <th>Processed</th>
                <th>Bad</th>
                <th>Remaining</th>
                <th>Elapsed</th>
                <th>Actions</th>
            </tr>
        </thead>
        <tbody><!-- filled in by the script below --></tbody>
    </table>

    <cfoutput>
    <script>
        // Built server-side so the links stay correct under the app's routing.
        var STATUS_URL   = "#event.buildLink( 'jobs.status' )#";
        var CANCEL_URL   = "#event.buildLink( 'jobs.cancel' )#";
        var REMOVE_URL   = "#event.buildLink( 'jobs.remove' )#";
        var DOWNLOAD_URL = "#event.buildLink( 'jobs.download' )#";
    </script>
    </cfoutput>

    <script>
        var TERMINAL = [ "completed", "failed", "canceled", "interrupted" ];

        function esc( value ) {
            return String( value == null ? "" : value )
                .replace( /&/g, "&amp;" ).replace( /</g, "&lt;" ).replace( />/g, "&gt;" );
        }

        function fmtElapsed( ms ) {
            if ( !ms ) return "-";
            var s = Math.round( ms / 1000 );
            return s < 60 ? s + "s" : Math.floor( s / 60 ) + "m " + ( s % 60 ) + "s";
        }

        function render( jobs ) {
            var rows = jobs.map( function( job ) {
                var p = job.progress || {};
                var done = TERMINAL.indexOf( job.status ) !== -1;
                var actions = "";
                if ( !done ) {
                    actions += '<a class="action" href="' + CANCEL_URL + '?id=' + job.id + '">cancel</a>';
                }
                if ( job.status === "completed" ) {
                    actions += '<a class="action" href="' + DOWNLOAD_URL + '?id=' + job.id + '">download</a>';
                }
                actions += '<a class="action" href="' + REMOVE_URL + '?id=' + job.id + '">remove</a>';
                return '<tr>'
                    + '<td>' + esc( job.url ) + '</td>'
                    + '<td class="status ' + esc( job.status ) + '">' + esc( job.status ) + '</td>'
                    + '<td>' + ( p.pagesFound || 0 ) + '</td>'
                    + '<td>' + ( p.urlsProcessed || 0 ) + '</td>'
                    + '<td>' + ( p.badUrls || 0 ) + '</td>'
                    + '<td>' + ( p.remaining || 0 ) + '</td>'
                    + '<td>' + fmtElapsed( p.elapsedMs ) + '</td>'
                    + '<td>' + actions + '</td>'
                    + '</tr>';
            } );
            document.querySelector( "#jobsTable tbody" ).innerHTML =
                rows.length ? rows.join( "" ) : '<tr><td colspan="8" class="muted">No jobs yet.</td></tr>';
        }

        function poll() {
            fetch( STATUS_URL )
                .then( function( r ) { return r.json(); } )
                .then( render )
                .catch( function() { /* transient; the next tick tries again */ } );
        }

        poll();
        setInterval( poll, 2000 );
    </script>
</body>
</html>

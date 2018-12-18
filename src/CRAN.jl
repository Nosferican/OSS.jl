using HTTP: request
using LazyJSON: value
using SQLite: DB, Query, drop!
using Gumbo: parsehtml

function parse_license(license)
    if occursin("Apache", license)
        output = "Apache"
    elseif occursin("MIT", license)
        output = "MIT"
    elseif occursin("BSD", license)
        output = "BSD"
    elseif occursin(r"(CPL|EPL|Common Public)", license)
        output = "EPL"
    elseif occursin("Artistic", license)
        output = "Artistic"
    elseif occursin("CeCILL", license)
        output = "CECILL"
    elseif occursin(r"(Mozilla|MPL)", license)
        output = "MPL"
    elseif occursin(r"((?<!A)GPL|General Public)", license)
        output = "GPL"
    elseif occursin(r"(AGPL|Affero)", license)
        output = "AGPL"
    elseif occursin("EUPL", license)
        output = "EUPL"
    elseif occursin("Lucent", license)
        output = "LPL"
    elseif occursin("Unlimited", license)
        output = "FSFUL"
    elseif occursin("BSL", license)
        output = "BSL"
    elseif occursin(r"(CC|Creative)", license)
        output = "CC"
    elseif occursin("ACM", license)
        output = "ACM"
    elseif occursin(r"<a href=\"LICEN[CS]E\">", license)
        output = "Custom"
    elseif isempty(license)
        output = "GPL"
    else
        output = license
    end
    output
end
osi(license) = license ∈ ["Apache", "MIT", "BSD", "EPL", "Artistic", "CECILL",
                          "MPL", "GPL", "AGPL", "EUPL", "LPL", "BSL"]

function CRAN!()
    # Connect to the database
    db = DB("data/OSS.db")
    drop!(db, "cran_pkg", ifexists = true)
    drop!(db, "cran_contributors", ifexists = true)
    drop!(db, "cran_deps", ifexists = true)
    Query(db, "create table cran_pkg (
               pkg varchar not null,
               version varchar not null,
               license varchar not null,
               osi bool not null,
               slug varchar,
               primary key (pkg)
               );")
    Query(db, "create table cran_contributors (
               pkg varchar not null,
               name varchar not null,
               author bool not null,
               compiler bool not null,
               contributor bool not null,
               copyright_holder bool not null,
               creator bool not null,
               thesis_advisor bool not null,
               translator bool not null,
               foreign key (pkg) references cran_pkg(pkg)
               );")
    Query(db, "create table cran_deps (
               pkg varchar,
               deps varchar,
               foreign key (pkg) references cran_pkg(pkg)
               );")
    # Timestamp: 2012-12-17
    # This code is to query available packages in CRAN
    # response = request("GET", "https://cran.r-project.org/web/packages/available_packages_by_name.html")
    # response.status == 200 || throw(ArgumentError("Could not connect to CRAN"))
    # body = String(response.body)
    # pkgs = eachmatch(r"(?<=\.{2}/\.{2}/web/packages/).*(?=/index\.html)",
    #                  body) |>
    #        (x -> getproperty.(x, :match))
    # write("data/CRAN/_index.txt", join(pkgs, '\n'))
    # Read available packages in CRAN
    pkgs = "data/CRAN/_index.txt" |> read |> String |> (x -> split(x, '\n'))
    # Downloads and save the package information
    for pkg ∈ pkgs
        file = "data/CRAN/$pkg.html"
        if ~isfile(file) # Change to true when updating
            response = request("GET", "https://cran.r-project.org/web/packages/$pkg/index.html")
            String(response.body) |> (x -> write(file, x))
        end
    end
    for pkg ∈ pkgs
        html = "data/CRAN/$pkg.html" |> read |> String |> parsehtml
        vals = string.(getindex.(getindex.(html.root[2][3][1][:], 1), 1))
        version = findfirst(isequal("Version:"), vals) |>
            (x -> html.root[2][3][1][x][2]) |>
            string |>
            (x -> match(r"\p{N}+(\.\p{N}+){0,2}", x).match) |>
            VersionNumber
        license = findfirst(isequal("License:"), vals) |>
            (x -> html.root[2][3][1][x][2]) |>
            string |>
            (x -> eachmatch(r"(?<=>).+?(?=</)", x)) |>
            (x -> getproperty.(x, :match)) |>
            (x -> join(x, ',')) |>
            parse_license
        osi_approved = osi(license)
        dependency = Vector{String}()
        deps = findfirst(isequal("Depends:"), vals)
        imps = findfirst(isequal("Imports:"), vals)
        if ~isa(deps, Nothing)
            html.root[2][3][1][deps][2] |>
            string |>
            (x -> replace(x, r"(<.*?>|\(.*?\))" => "")) |>
            (x -> split(x, ',')) |>
            (x -> strip.(x)) |>
            (x -> append!(dependency, x))
        end
        if ~isa(imps, Nothing)
            html.root[2][3][1][imps][2] |>
            string |>
            (x -> replace(x, r"(<.*?>|\n)" => "")) |>
            (x -> replace(x, r"\(.*?\)" => "")) |>
            (x -> split(x, ',')) |>
            (x -> strip.(x)) |>
            (x -> append!(dependency, x))
        end
        filter!(!isequal("R"), dependency) |> sort!
        author = findfirst(isequal("Author:"), vals)
        authors = html.root[2][3][1][author][2][1] |>
            string |>
            (x -> replace(x, r"<.*?>" => "")) |>
            (x -> split(x, r",(?!\s*(aut|com|ctb|cph|cre|ths|trl)[,\]])\s*"))
        maintainer = findfirst(isequal("Maintainer:"), vals)
        maintainers = html.root[2][3][1][maintainer][2] |>
            string |>
            (x -> replace(x, r"</*td>" => "")) |>
            (x -> replace(x, " at " => "@"))
        email = match(r"(?<=<).*(?=>)", maintainers) |>
            (x -> isa(x, Nothing) ? "null" : x.match)
        slug = "null"
        bugs = findfirst(isequal("BugReports:"), vals)
        if ~isa(bugs, Nothing)
            link = html.root[2][3][1][bugs][2] |>
                string |>
                (x -> replace(x, r"/+" => "/")) |>
                (x -> match(r"(?<=github\.com/).*?/.*?(?=(/|\"))", x))
            if isa(link, RegexMatch)
                slug = "'$(link.match)'"
            end
        end
        URL = findfirst(isequal("URL:"), vals)
        if ~isa(URL, Nothing)
            link = html.root[2][3][1][URL][2] |>
                string |>
                (x -> replace(x, r"/+" => "/")) |>
                (x -> match(r"(?<=github\.com/).*?/.*?(?=(/|\"))", x))
            if isa(link, RegexMatch)
                slug = "'$(link.match)'"
            end
        end
        Query(db, "insert into cran_pkg values (" *
                  "'$pkg', '$version', '$license', $osi_approved, $slug)")
        for author ∈ authors
            # author = authors[1]
            name = match(r".*?(?=(\[|$))", author).match |>
                (x -> strip(x, ['\'',' '])) |>
                (x -> replace(x, "'" => "''"))
            role = match(r"(?<=\[).*(?=\])", author)
            if isa(role, Nothing)
                author = compiler = contributor = copyright_holder = creator =
                thesis_advisor = translator = false
            else
                role = role.match
                author = occursin("aut", role)
                compiler = occursin("com", role)
                contributor = occursin("ctb", role)
                copyright_holder = occursin("copyright_holder", role)
                creator = occursin("cre", role)
                thesis_advisor = occursin("ths", role)
                translator = occursin("trl", role)
            end
            Query(db, "insert into cran_contributors values (
                       '$pkg', '$name', $author, $compiler,
                       $contributor, $copyright_holder, $creator,
                       $thesis_advisor, $translator)")
        end
        for deps ∈ dependency
            Query(db, "insert into cran_deps values (" *
                      "'$pkg', '$deps')")
        end
    end
end
CRAN!()

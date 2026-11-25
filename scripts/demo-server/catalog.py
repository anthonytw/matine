"""The demo library: every title, its license, its own synopsis, and which frames of the film make its art.

All text here is written for this demo (nothing copied from Wikipedia/TMDB/IMDb). All art is made from frames of the
films themselves (build-media.py). Times are seconds into the SOURCE file: `poster_t`/`backdrop_t` are the art frames,
`frames` are the handful the placeholder video is built from. `runtime_s` is the runtime the placeholder reports.
"""
A = "https://archive.org/download/"
BL = "https://download.blender.org/"
FOUNDATION = "Blender Foundation"
STUDIO = "Blender Studio"

MOVIES = [
    dict(slug="bbb", title="Big Buck Bunny", year=2008, runtime_s=596, mpaa="G",
         url=A + "BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4",
         genres=["Animation", "Comedy", "Family"], tags=["open movie", "kid friendly", "creative commons"],
         director="Sacha Goedegebure", studio=FOUNDATION, tagline="Don't poke the bunny.",
         plot="An enormous, gentle rabbit wakes up to a perfect spring morning, until three rodent bullies decide to "
              "spoil it. He bides his time, then answers with a string of cheerfully elaborate traps.",
         license="CC BY 3.0", credit="(c) Blender Foundation | www.bigbuckbunny.org",
         poster_t=223, poster_fx=0.5, backdrop_t=134, frames=[134, 193, 223, 253, 342, 402, 432, 491]),
    dict(slug="ed", title="Elephants Dream", year=2006, runtime_s=654, mpaa="PG",
         url=BL + "ED/elephantsdream-720-h264-st-aac.mov",
         genres=["Animation", "Science Fiction", "Fantasy"], tags=["open movie", "creative commons"],
         director="Bassam Kurdali", studio="Orange Open Movie Project",
         plot="Two travelers wander through a vast, humming machine of cables and strange rooms. One is eager to "
              "understand it, the other is certain he already does, and their friendship frays as its rules reveal themselves.",
         license="CC BY 2.5", credit="(c) copyright 2006, Blender Foundation / Netherlands Media Art Institute / www.elephantsdream.org",
         poster_t=411, poster_fx=0.55, backdrop_t=49, frames=[49, 115, 246, 411, 444, 509]),
    dict(slug="sintel", title="Sintel", year=2010, runtime_s=888, mpaa="PG",
         url=BL + "durian/movies/Sintel.2010.1080p.mkv",
         genres=["Animation", "Fantasy", "Adventure"], tags=["open movie", "creative commons", "dragons"],
         director="Colin Levy", studio=FOUNDATION, tagline="Some friendships are worth the whole road.",
         plot="A lone young woman befriends a wounded baby dragon, then loses it. Her search leads across snowfields, "
              "cities and deserts to a reunion she did not expect.",
         license="CC BY 3.0", credit="(c) Blender Foundation | www.sintel.org",
         poster_t=288, poster_fx=0.38, backdrop_t=155, frames=[155, 199, 288, 333, 421, 555],
         resume=0.4),
    dict(slug="tos", title="Tears of Steel", year=2012, runtime_s=734, mpaa="PG-13",
         url=BL + "demo/movies/ToS/tears_of_steel_720p.mov",
         genres=["Science Fiction", "Action"], tags=["open movie", "creative commons", "live action"],
         director="Ian Hubert", studio=FOUNDATION,
         plot="In a future Amsterdam, a team of scientists and soldiers stages one last experiment to undo an old "
              "mistake, with a robot menace closing in around them.",
         license="CC BY 3.0", credit="(c) Blender Foundation | mango.blender.org",
         poster_t=201, poster_fx=0.3, backdrop_t=128, frames=[55, 91, 128, 165, 201, 238],
         watched=True),
    dict(slug="spring", title="Spring", year=2019, runtime_s=464, mpaa="PG",
         url=A + "springopenmovie/springopenmovie.mp4",
         genres=["Animation", "Fantasy", "Family"], tags=["open movie", "kid friendly", "creative commons"],
         director="Andy Goralczyk", studio=STUDIO, tagline="Every season has a keeper.",
         plot="A young shepherd girl and her dog climb to a high mountain meadow, where they must face the old spirits "
              "that rule the seasons so that spring can come again.",
         license="CC BY 4.0", credit="(c) Blender Foundation | cloud.blender.org/spring",
         poster_t=313, poster_fx=0.5, backdrop_t=382, frames=[58, 174, 220, 313, 359, 382],
         favorite=True),
    dict(slug="cosmos", title="Cosmos Laundromat: First Cycle", year=2015, runtime_s=730, mpaa="PG",
         url=A + "CosmosLaundromatFirstCycle/Cosmos%20Laundromat%20-%20First%20Cycle%20%281080p%29.mp4",
         genres=["Animation", "Fantasy", "Comedy"], tags=["open movie", "creative commons"],
         director="Mathieu Auvray", studio=FOUNDATION,
         plot="A weary sheep named Franck meets a cheerful stranger who offers him a fresh start, in any shape he can "
              "imagine. Be careful what you wish for.",
         license="CC BY 3.0", credit="(c) Blender Foundation | gooseberry.blender.org",
         poster_t=273, poster_fx=0.42, backdrop_t=346, frames=[91, 200, 273, 346, 492, 529]),
    dict(slug="sprite", title="Sprite Fright", year=2021, runtime_s=629, mpaa="PG",
         url=A + "sprite-fright/Sprite%20Fright%20-%20Open%20Movie%20by%20Blender%20Studio-804p.mp4",
         genres=["Animation", "Comedy", "Horror", "Family"], tags=["open movie", "creative commons", "kid friendly"],
         director="Mike Pearce", studio=STUDIO,
         plot="A noisy group of teenagers camps in an English forest in the 1980s and disturbs the gentle mushroom "
              "folk who live there. Woken up, the mushrooms turn out to be far less gentle.",
         license="CC BY", credit="(c) Blender Studio | studio.blender.org/films/sprite-fright",
         poster_t=204, poster_fx=0.5, backdrop_t=47, frames=[15, 78, 172, 204, 330, 518]),
    dict(slug="notld", title="Night of the Living Dead", year=1968, runtime_s=5755, mpaa="NR",
         url=A + "night-of-the-living-dead-1968-720p/Night%20of%20the%20Living%20Dead%20%281968%29%20720p.mp4",
         genres=["Horror"], tags=["public domain", "black and white", "classic"],
         director="George A. Romero", studio="Image Ten",
         plot="Strangers take shelter in a rural farmhouse for one night while the dead walk outside. The fear and "
              "quarrels inside prove as dangerous as the creatures at the door.",
         license="Public domain (US)", credit="Published in 1968 without a copyright notice",
         poster_t=2445, poster_fx=0.5, backdrop_t=719, frames=[431, 719, 1294, 2445, 3021, 3884, 5611]),
    dict(slug="general", title="The General", year=1926, runtime_s=4680, mpaa="NR",
         url=A + "General.1926/Genera%C5%82.%281926%29.mp4",
         genres=["Comedy", "Action", "Adventure"], tags=["public domain", "silent film", "black and white", "classic"],
         director="Buster Keaton, Clyde Bruckman", studio="United Artists",
         plot="A railway engineer chases the raiders who stole his beloved locomotive, and, by accident, his "
              "sweetheart along with it. Stunts and slapstick roll down the whole line.",
         license="Public domain (US)", credit="Published in 1926; US copyright expired",
         poster_t=4003, poster_fx=0.4, backdrop_t=4963, frames=[1120, 1441, 1761, 2081, 4003, 4963, 5604],
         resume=0.25),
    dict(slug="sherlock", title="Sherlock Jr.", year=1924, runtime_s=2673, mpaa="NR",
         url=A + "sherlockjr1924_201909/Sherlock%20Jr.%20-%20Buster%20Keaton%20%281924%29%20HD%20%5B720p%5D.mp4",
         genres=["Comedy", "Fantasy"], tags=["public domain", "silent film", "black and white", "classic"],
         director="Buster Keaton", studio="Metro Pictures",
         plot="A movie projectionist who dreams of being a great detective is framed for a theft. He falls asleep "
              "and steps into the film on the screen, where he really is one.",
         license="Public domain (US)", credit="Published in 1924; US copyright expired",
         poster_t=1050, poster_fx=0.4, backdrop_t=1260, frames=[210, 420, 630, 1050, 1260, 1680, 2100, 2310],
         favorite=True),
    dict(slug="gtr", title="The Great Train Robbery", year=1903, runtime_s=691, mpaa="NR",
         url=A + "the-great-train-robbery-1903/The%20Great%20Train%20Robbery%20%281903%29.mp4",
         genres=["Western", "Crime"], tags=["public domain", "silent film", "black and white", "classic"],
         director="Edwin S. Porter", studio="Edison Manufacturing Company", crop="crop=960:720:160:0",
         plot="Outlaws take over a telegraph office, rob a train and ride into the woods with the loot, with a posse "
              "close behind, in one of the earliest films that tells a story.",
         license="Public domain (US)", credit="Published in 1903; US copyright expired",
         poster_t=673, poster_fx=0.5, backdrop_t=362, frames=[120, 155, 259, 362, 466, 570]),
    dict(slug="nosferatu", title="Nosferatu", year=1922, runtime_s=5514, mpaa="NR",
         url=A + "Nosferatu1922/Nosferatu.mp4",
         genres=["Horror", "Fantasy"], tags=["public domain", "silent film", "black and white", "classic"],
         director="F. W. Murnau", studio="Prana Film",
         plot="A young estate agent travels to a remote castle to close a property deal, and unknowingly brings its "
              "ancient, shadowy owner back to his quiet harbor town.",
         license="Public domain (US)", credit="Published in 1922; US copyright expired",
         poster_t=5376, poster_fx=0.5, fit=True, backdrop_t=689, frames=[413, 689, 1516, 1792, 2067, 2619, 3170, 3997, 4273, 5100, 5376]),
    dict(slug="wingit", title="Wing It!", year=2023, runtime_s=237, mpaa="G",
         url=A + "wing_it/wing_it.mp4",
         genres=["Animation", "Comedy", "Family", "Adventure"], tags=["open movie", "kid friendly", "creative commons"],
         director="Rik Schutte", studio=STUDIO, favorite=True,
         plot="A dog in an astronaut suit and a cat in flying goggles build a machine from odds and ends, then take it "
              "out for a very ambitious first flight.",
         license="CC BY 4.0", credit="(CC) Blender Foundation | studio.blender.org",
         poster_t=41, poster_fx=0.5, backdrop_t=124, frames=[17, 41, 65, 88, 112, 124, 148, 171, 195]),
    dict(slug="coffee", title="Coffee Run", year=2020, runtime_s=185, mpaa="PG",
         url=A + "coffee-run/Coffee%20Run.mp4",
         genres=["Animation", "Comedy", "Science Fiction"], tags=["open movie", "creative commons"],
         director="Hjalti Hjalmarsson", studio=STUDIO,
         plot="A woman, a city and one very urgent cup of coffee: a stylish dash across rooftops and ziplines with "
              "a caffeinated mission.",
         license="CC BY 4.0", credit="(CC) Blender Foundation | studio.blender.org",
         poster_t=50, poster_fx=0.74, backdrop_t=41, frames=[13, 23, 32, 41, 50, 69, 78, 96, 115, 133]),
    dict(slug="trip", title="A Trip to the Moon", year=1902, runtime_s=840, mpaa="NR",
         url=A + "a-trip-to-the-moon-1902-tmdbid-775/a-trip-to-the-moon-%281902%29-%5Btmdbid-775%5D-1080p-vp9.mp4",
         genres=["Science Fiction", "Fantasy", "Adventure"], tags=["public domain", "silent film", "black and white", "classic", "space"],
         director="Georges Melies", studio="Star Film Company", tagline="The original space opera.",
         plot="A group of squabbling astronomers fires a capsule from a giant cannon into the eye of the Moon, and finds "
              "a cavern world of mushrooms and strange inhabitants. The trip home is even less dignified.",
         license="Public domain (US)", credit="Published in 1902; US copyright expired",
         poster_t=365, poster_fx=0.5, backdrop_t=480, frames=[57, 211, 365, 403, 480, 519, 557, 634, 672]),
    dict(slug="caligari", title="The Cabinet of Dr. Caligari", year=1920, runtime_s=4637, mpaa="NR",
         url=A + "the-cabinet-of-dr.-caligari-1920./The%20Cabinet%20Of%20Dr.%20Caligari%20%281920%29..mp4",
         genres=["Horror", "Fantasy", "Mystery"], tags=["public domain", "silent film", "german expressionism", "classic"],
         director="Robert Wiene", studio="Decla-Bioscop",
         plot="A traveling showman and his sleepwalking attraction arrive at a fairground just as a string of murders "
              "begins. A young man's search for the culprit leads somewhere stranger than the crimes.",
         license="Public domain (US)", credit="Published in 1920; US copyright expired",
         poster_t=347, poster_fx=0.5, backdrop_t=579, frames=[347, 579, 1507, 2202, 2898, 3129, 3825, 4057, 4289]),
    dict(slug="nanook", title="Nanook of the North", year=1922, runtime_s=4712, mpaa="NR",
         url=A + "Nanook-of-the-North/Nanook%20of%20the%20North%20%281922%29.mp4", crop="crop=480:360:80:0",
         genres=["Documentary", "Adventure"], tags=["public domain", "silent film", "black and white", "classic", "arctic"],
         director="Robert J. Flaherty", studio="Revillon Freres",
         plot="A silent portrait of an Inuit hunter and his family through a hard Arctic year: hunting, travel across "
              "the ice, and a shelter built from snow.",
         license="Public domain (US)", credit="Published in 1922; US copyright expired",
         poster_t=824, poster_fx=0.5, fit=True, backdrop_t=2002, frames=[353, 589, 824, 1060, 1531, 2002, 2238, 2709, 3180, 3887]),
    dict(slug="metropolis", title="Metropolis", year=1927, runtime_s=9011, mpaa="NR",
         url=A + "metropolis-1927_202511/Metropolis%201927.mp4",
         genres=["Science Fiction", "Drama"], tags=["public domain", "silent film", "black and white", "classic", "future city"],
         director="Fritz Lang", studio="UFA",
         plot="In a gleaming future city, the son of its master falls for a woman who preaches patience to the "
              "workers living below. The gap between the towers and the machines is about to break open.",
         license="Public domain (US)", credit="Published in 1927; US copyright expired (film shots only, no restoration titles)",
         poster_t=675, poster_fx=0.5, backdrop_t=1126, frames=[225, 675, 1126, 1576, 2027, 2478, 2928, 3379, 4730, 5181, 5631, 6983, 8335]),
    dict(slug="steamboat", title="Steamboat Bill, Jr.", year=1928, runtime_s=4147, mpaa="NR",
         url=A + "steamboat_bill_ipod/steamboat_bill.mp4",
         genres=["Comedy", "Action"], tags=["public domain", "silent film", "black and white", "classic", "stunts"],
         director="Charles Reisner, Buster Keaton", studio="United Artists", resume=0.3,
         plot="A college boy arrives to meet the riverboat captain father he barely knows, who is horrified to find "
              "him a dandy. A rival steamboat, a jail break and a monster storm put them both to the test.",
         license="Public domain (US)", credit="Published in 1928; US copyright expired",
         poster_t=518, poster_fx=0.5, fit=True, backdrop_t=1347, frames=[103, 518, 725, 933, 1140, 1347, 1762, 2177, 2591, 2799, 3213, 3421, 3835]),
]

SHOW = dict(
    slug="caminandes", title="Caminandes", year=2013, mpaa="TV-G",
    genres=["Animation", "Comedy", "Family"], tags=["open movie", "kid friendly", "creative commons", "llamas"],
    director="Pablo Vazquez", studio=FOUNDATION, favorite=True,
    plot="Koro is a young llama in Patagonia who wants one thing: a bite of something tasty. Every short puts a new "
         "obstacle between him and the snack: a road, a fence, a penguin.",
    license="CC BY 3.0", credit="(c) Blender Foundation | caminandes.com",
    poster_t=116, poster_fx=0.46, backdrop_t=131, poster_ep="cam3",
    episodes=[
        dict(slug="cam1", n=1, title="Llama Drama", original="Caminandes 1: Llama Drama", year=2013, runtime_s=90, thumb_t=15, watched=True,
             url=A + "Caminandes1LlamaDrama/01_llama_drama_1080p.mp4", frames=[15, 24, 47, 60, 74, 83],
             plot="Koro the llama and a narrow mountain road, with a car that has no plans to slow down."),
        dict(slug="cam2", n=2, title="Gran Dillama", original="Caminandes 2: Gran Dillama", year=2013, runtime_s=146, thumb_t=40, resume=0.5,
             url=A + "Caminandes2GranDillama/02_gran_dillama_1080p.mp4", frames=[10, 25, 40, 62, 69, 105],
             plot="Koro spots berries on the far side of an electric fence, and a nearby armadillo gives him an idea."),
        dict(slug="cam3", n=3, title="Llamigos", original="Caminandes 3: Llamigos", year=2016, runtime_s=150, thumb_t=71,
             url=A + "CaminandesLlamigos/Caminandes_%20Llamigos-1080p.mp4", frames=[11, 26, 56, 71, 93, 131],
             plot="Winter has come and food is scarce. Koro and a pesky penguin, Oti, both want the very last berry."),
    ],
)

NASA = dict(
    slug="apollo", title="Apollo: The NASA Films", year=1969, mpaa="TV-G",
    genres=["Documentary", "History"], tags=["NASA", "space", "moon landing", "public domain"],
    director="NASA", studio="NASA",
    plot="Four films NASA made about its Apollo missions, from the first trip around the Moon to the hills of Hadley.",
    license="Public domain (US government work)", credit="Courtesy NASA",
    poster_t=213, poster_fx=0.5, backdrop_t=1066, poster_ep="nasa11", backdrop_ep="nasa11", poster_label="1968 - 1971",
    episodes=[
        dict(slug="nasa8", n=1, title="Apollo 8: Go for TLI", original="Apollo 8: Go for TLI", year=1969, runtime_s=1313,
             thumb_t=426, url=A + "Jsc-500Apollo8-goForTli.wmv/Jsc-500Apollo8-goForTli.mp4",
             frames=[98, 229, 426, 492, 558, 689, 886, 1148, 1280],
             plot="The first voyage around the Moon, at Christmas 1968, told through air-to-ground conversations, "
                  "mission control and photographs taken from lunar orbit."),
        dict(slug="nasa11", n=2, title="The Eagle Has Landed: The Flight of Apollo 11", original="Eagle Has Landed: The Flight of Apollo 11",
             year=1969, runtime_s=1707, thumb_t=213, resume=0.45, url=A + "Hq-194_apollo11TheEagleHasLanded2.wmv/Hq-194_apollo11TheEagleHasLanded2.wmv",
             frames=[128, 213, 298, 725, 981, 1066, 1152, 1237],
             plot="The first landing on the Moon, in July 1969, from launch through the moonwalk to splashdown, seen "
                  "through television, film and still photographs."),
        dict(slug="nasa12", n=3, title="Apollo 12: Pinpoint for Science", original="Apollo 12: Pinpoint for Science",
             year=1970, runtime_s=1738, thumb_t=738, url=A + "Jsc-536_apollo12PinpointForScience.wmv/Jsc-536_apollo12PinpointForScience.mp4",
             frames=[130, 217, 304, 651, 738, 912, 1173, 1346],
             plot="The second lunar landing: a pinpoint touchdown beside an old probe, a station of scientific "
                  "instruments and a long geology walk."),
        dict(slug="nasa15", n=4, title="Apollo 15: In the Mountains of the Moon", original="Apollo 15: In the Mountains of the Moon",
             year=1971, runtime_s=1745, thumb_t=654, crop="crop=640:480:107:0",
             url=A + "Jsc-572Apollo15-InTheMountainsOfTheMoon/Jsc-572Apollo15-InTheMountainsOfTheMoon.mp4",
             frames=[305, 567, 654, 741, 916, 1003, 1177, 1352, 1439],
             plot="Three days among the mountains and canyons of the Hadley region: the first lunar rover, a hammer "
                  "and a feather dropped together, and a small satellite released on the way home."),
    ],
)
SHOWS = [SHOW, NASA]

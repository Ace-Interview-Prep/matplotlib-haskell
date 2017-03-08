{-# LANGUAGE ExtendedDefaultRules #-}
-----------------------------------------------------------------------------
-- |
-- Matplotlib bindings and an interface to easily bind to new portions of the
-- API. The most essential parts of Matplotlib are wrapped and exposed to
-- Haskell through an interface that allows extenisbility. Code is generated on
-- the fly and python is called.
--
-- This is not a very Haskell-ish library. Type safety is non-existent, it's
-- easy to generate incorrect Python code, in exchange for being able to bind to
-- arbitrary matplotlib APIs with ease, so it's also easy to generate correct
-- python code.
--
-- The generated code follows a few simple conventions.  data is always loaded
-- into a data variable that is a python array. Data is transffered via
-- json. This data variable is indexed by various rendering commands.
--
-- Functions which start with the word data operate on the data array, arguments
-- are python code that should access that array. Most other functions take
-- haskell objects and load them into python.
--
-- This module should expose enough tools so that you can bind any part of the
-- matplotlib API. A binding with options, such as that of 'plot', looks like:
--
-- @
--   readData (x, y)
--   % mp \# "p = plot.plot(data[" \# a \# "], data[" \# b \# "]" ## ")"
--   % mp \# "plot.xlabel(" \# str label \# ")"
-- @
--
-- Where important functions are:
--
--   [@'readData'@] Load the given data into the python data array by serializing it to JSON.
--   [@'%'@] Sequence two plots
--   [@'mp'@] Create an empty plot
--   [@'#'@] Append python code to the last command in a plot
--   [@'##'@] Just like '#' but also adds in a placeholder for an options list
--
-- You can call this plot with
--
-- > plot [1,2,3,4,5,6] [1,3,2,5,2] @@ [o1 "go-", o2 "linewidth" 2]
--
-- where '@@' applies an options list replacing the last '##'
--
--  [@'o1'@] A single positional option. The value is rendered into python as
--  the appropriate datatype. Strings become python strings, bools become bools,
--  etc. If you want to insert code verbatim into an option use 'lit'. If you
--  want to have a raw string with no escapes use 'raw'.
--  [@'o2'@] A keyword option. The key is awlays a string, the value is treated
--  the same way that the option in 'o1' is treated.
--
-- Right now there's no easy way to bind to an option other than the last one
-- unless you want to pass options in as parameters.
--
-- TODO The generated Python code should follow some invariants. It must maintain the
-- current figure in "fig", all available axes in "axes", and the current axis
-- in "ax".
-----------------------------------------------------------------------------

module Graphics.Matplotlib
  ( module Graphics.Matplotlib
    -- * Creating custom plots and applying options
  , Matplotlib(), Option(),(@@), (%), o1, o2, (##), (#), mp, def, readData,
    str, raw, lit, updateAxes)
where
import Data.List
import Data.Aeson
import Graphics.Matplotlib.Internal

-- * Running a plot

-- | Show a plot, blocks until the figure is closed
onscreen :: Matplotlib -> IO (Either String String)
onscreen m = withMplot m (\str -> python $ pyIncludes ++ str ++ pyDetach ++ pyOnscreen)

-- | Print the python code that would be executed
code :: Matplotlib -> IO String
code m = withMplot m (\str -> return $ unlines $ pyIncludes ++ str ++ pyDetach ++ pyOnscreen)

-- | Save to a file
figure :: [Char] -> Matplotlib -> IO (Either String String)
figure filename m = withMplot m (\str -> python $ pyIncludes ++ str ++ pyFigure filename)

-- * Useful plots

-- | Plot the cross-correlation and autocorrelation of several variables. TODO Due to
-- a limitation in the options mechanism this takes explicit options.
xacorr xs ys opts = readData (xs, ys)
  % addSubplot 2 1 1
  % xcorr xs ys @@ opts
  % grid True
  % axhline 0 @@ [o1 0, o2 "color" "black", o2 "lw" 2]
  % addSubplot 2 1 2 @@ [o2 "sharex" $ lit "ax"]
  % acorr xs @@ opts
  % grid True
  % axhline 0 @@ [o2 "color" "black", o2 "lw" 2]

-- | Plot a histogram for the given values with 'bins'
histogram :: (MplotValue val, ToJSON t) => t -> val -> Matplotlib
histogram values bins = readData [values] % dataHistogram 0 bins

-- | Plot a 2D histogram for the given values with 'bins'
histogram2D x y = readData [x,y] %
  mp # "plot.hist2d(data[0], data[1]" ## ")"

-- | Plot the given values as a scatter plot
scatter :: (ToJSON t1, ToJSON t) => t1 -> t -> Matplotlib
scatter x y = readData (x, y)
  % mp # "axes[0].scatter(data[0], data[1]" ## ")"

-- | Plot a line
line :: (ToJSON t1, ToJSON t) => t1 -> t -> Matplotlib
line x y = plot x y `def` [o1 "-"]

-- | Like 'plot' but takes an error bar value per point
errorbar xs ys errs = readData (xs, ys, errs)
  % mp # "ax.errorbar(data[0], data[1], yerr=data[2]" ## ")"

-- | Plot a line given a function that will be executed for each element of
-- given list. The list provides the x values, the function the y values.
lineF :: (ToJSON a, ToJSON b) => (a -> b) -> [a] -> Matplotlib
lineF f l = plot l (map f l) `def` [o1 "-"]

boxplot l = readData l
  % mp # "ax.boxplot(data" ## ")"

-- | Given a grid of x and y values and a number of steps call the given
-- function and plot the 3D contour
contourF :: (ToJSON val, MplotValue val, Ord val) => (Double -> Double -> val) -> Double -> Double -> Double -> Double -> Double -> Matplotlib
contourF f xStart xEnd yStart yEnd steps = contour xs ys zs
  where xs = mapLinear (\x -> (mapLinear (\_ -> x) yStart yEnd steps)) xStart xEnd steps
        ys = mapLinear (\_ -> (mapLinear (\y -> y) yStart yEnd steps)) xStart xEnd steps
        zs = mapLinear (\x -> (mapLinear (\y -> f x y) yStart yEnd steps)) xStart xEnd steps

-- | Given a grid of x and y values and a number of steps call the given
-- function and plot the 3D projection
projectionsF :: (ToJSON val, MplotValue val, Ord val) => (Double -> Double -> val) -> Double -> Double -> Double -> Double -> Double -> Matplotlib
projectionsF f xStart xEnd yStart yEnd steps = projections xs ys zs
  where xs = mapLinear (\x -> (mapLinear (\_ -> x) yStart yEnd steps)) xStart xEnd steps
        ys = mapLinear (\_ -> (mapLinear (\y -> y) yStart yEnd steps)) xStart xEnd steps
        zs = mapLinear (\x -> (mapLinear (\y -> f x y) yStart yEnd steps)) xStart xEnd steps

-- | Plot x against y interpolating with n steps
plotInterpolated :: (MplotValue val, ToJSON t, ToJSON t1) => t1 -> t -> val -> Matplotlib
plotInterpolated x y n =
  readData (x, y)
  % interpolate 0 1 n
  % dataPlot 0 1 `def` [o1 "-"]

-- | A handy function to plot a line between two points give a function and a number o steps
plotMapLinear :: ToJSON b => (Double -> b) -> Double -> Double -> Double -> Matplotlib
plotMapLinear f s e n = line xs ys
  where xs = mapLinear (\x -> x) s e n
        ys = mapLinear (\x -> f x) s e n

-- | Plot a line between 0 and the length of the array with the given y values
line1 :: (Foldable t, ToJSON (t a)) => t a -> Matplotlib
line1 y = line [0..length y] y

-- | Plot a matrix
matShow :: ToJSON a => a -> Matplotlib
matShow d = readData d
            % (mp # "plot.matshow(data" ## ")")

-- | Plot a matrix
pcolor :: ToJSON a => a -> Matplotlib
pcolor d = readData d
            % (mp # "plot.pcolor(np.array(data)" ## ")")

-- | Plot a KDE of the given functions; a good bandwith will be chosen automatically
density :: [Double] -> Maybe (Double, Double) -> Matplotlib
density l maybeStartEnd =
  densityBandwidth l (((4 * (variance ** 5)) / (fromIntegral $ 3 * length l)) ** (1 / 5) / 3) maybeStartEnd
  where mean = foldl' (+) 0 l / (fromIntegral $ length l)
        variance = foldl' (+) 0 (map (\x -> sqr (x - mean)) l) / (fromIntegral $ length l)
        sqr x = x * x

-- * Matplotlib configuration

-- | Set an rcParams key-value
setParameter k v = mp # "matplotlib.rcParams["# str k #"] = " # v

-- | Enable or disable TeX
setTeX :: Bool -> Matplotlib
setTeX b = mp # "matplotlib.rcParams['text.usetex'] = " # b

-- | Enable or disable unicode
setUnicode :: Bool -> Matplotlib
setUnicode b = mp # "matplotlib.rcParams['text.latex.unicode'] = " # b

-- * Basic plotting commands

-- | Plot the 'a' and 'b' entries of the data object
dataPlot :: (MplotValue val, MplotValue val1) => val1 -> val -> Matplotlib
dataPlot a b = mp # "p = plot.plot(data[" # a # "], data[" # b # "]" ## ")"

-- | Plot the Haskell objects 'x' and 'y' as a line
plot :: (ToJSON t, ToJSON t1) => t1 -> t -> Matplotlib
plot x y = readData (x, y) % dataPlot 0 1

-- | Plot x against y where x is a date.
--   xunit is something like 'weeks', yearStart, monthStart, dayStart are an offset to x.
-- TODO This isn't general enough; it's missing some settings about the format. The call is also a mess.
dateLine :: (ToJSON t1, ToJSON t2) => t1 -> t2 -> String -> (Int, Int, Int) -> Matplotlib
dateLine x y xunit (yearStart, monthStart, dayStart) =
    readData (x, y)
  % mp # "data[0] = [datetime.timedelta("#xunit#"=i) + datetime.datetime("#yearStart#","#monthStart#","#dayStart#") for i in data[0]]"
  % dataPlot 0 1 `def` [o1 "-"]
  % mp # "ax.xaxis.set_major_formatter(DateFormatter('%B'))"
  % mp # "ax.xaxis.set_minor_locator(WeekdayLocator(byweekday=6))"

-- | Create a histogram for the 'a' entry of the data array
dataHistogram :: (MplotValue val1, MplotValue val) => val1 -> val -> Matplotlib
dataHistogram a bins = mp # "plot.hist(data[" # a # "]," # bins ## ")"

-- | Create a scatter plot accessing the given fields of the data array
dataScatter :: (MplotValue val1, MplotValue val) => val1 -> val -> Matplotlib
dataScatter a b = dataPlot a b `def` [o1 "."]

-- | Create a line accessing the given entires of the data array
dataLine :: (MplotValue val1, MplotValue val) => val1 -> val -> Matplotlib
dataLine a b = dataPlot a b `def` [o1 "-"]

-- | Create a 3D contour
contour xs ys zs =
  readData (xs, ys, zs)
  % axis3DProjection
  % surface 0 1 2
  % contourRaw 0 1 2 (maximum2 xs) (maximum2 ys) (minimum2 zs)
  % axis3DLabels xs ys zs

-- | Create a 3D projection
projections xs ys zs =
  readData (xs, ys, zs)
  % axis3DProjection
  % contourRaw 0 1 2 (maximum2 xs) (maximum2 ys) (minimum2 zs)
  % axis3DLabels xs ys zs

-- | Plot a 3D wireframe accessing the given elements of the data array
wireframe :: (MplotValue val2, MplotValue val1, MplotValue val) => val2 -> val1 -> val -> Matplotlib
wireframe a b c = mp # "ax.plot_wireframe(np.array(data[" # a # "]), np.array(data[" # b # "]), np.array(data[" # c # "]), rstride=1, cstride=1)"

-- | Plot a 3D surface accessing the given elements of the data array
surface :: (MplotValue val2, MplotValue val1, MplotValue val) => val2 -> val1 -> val -> Matplotlib
surface a b c = mp # "ax.plot_surface(np.array(data[" # a # "]), np.array(data[" # b # "]), np.array(data[" # c # "]), rstride=1, cstride=1, cmap=cm.Blues, alpha=0.3)"

-- | Plot a contour accessing the given elements of the data array
contourRaw :: (MplotValue val1, MplotValue val2, MplotValue val5,
               MplotValue val4, MplotValue val3, MplotValue val) =>
             val5 -> val4 -> val3 -> val2 -> val1 -> val -> Matplotlib
contourRaw a b c maxA maxB minC =
  mp # "ax.contour(data[" # a # "], data[" # b # "], data[" # c # "], zdir='z', offset=" # minC # ")"
  % mp # "ax.contour(data[" # a # "], data[" # b # "], data[" # c # "], zdir='x', offset=-" # maxA # ")"
  % mp # "ax.contour(data[" # a # "], data[" # b # "], data[" # c # "], zdir='y', offset=" # maxB #")"

-- | Draw a bag graph in a subplot
-- TODO Why do we need this?
subplotDataBar a width offset opts =
  mp # "ax.bar(np.arange(len(data[" # a # "]))+" # offset # ", data[" # a # "], " # width ## ")" @@ opts

-- | The default bar with
barDefaultWidth nr = 1.0 / (fromIntegral nr + 1)

-- | Create a set of labelled bars of a given height
subplotBarsLabelled valuesList labels optsList =
  subplotBars valuesList optsList
  % axisXTickSpacing (length $ head $ valuesList) (1.0 - barDefaultWidth (length valuesList) / 2.0)
  % axisXTickLabels labels

-- | Create a subplot and a set of labelled bars
-- TODO This is a mess..
subplotBars valuesList optsList =
  readData valuesList
  % addSubplot 1 1 1
  % (let width = barDefaultWidth (length valuesList) in
       foldl1 (%) (zipWith3 (\_ opts i -> subplotDataBar i width (width * i) opts) valuesList optsList [0..]))

-- | Update the data array to linearly interpolate between array entries
interpolate :: (MplotValue val, MplotValue val2, MplotValue val1) => val2 -> val1 -> val -> Matplotlib
interpolate a b n =
  (mp # "data[" # b # "] = mlab.stineman_interp(np.linspace(data[" # a # "][0],data[" # a # "][-1]," # n # "),data[" # a # "],data[" # b # "],None)")
  % (mp # "data[" # a # "] = np.linspace(data[" # a # "][0],data[" # a # "][-1]," # n # ")")

-- | Plot a KDE of the given functions with an optional start/end and a bandwidth h
densityBandwidth :: [Double] -> Double -> Maybe (Double, Double) -> Matplotlib
densityBandwidth l h maybeStartEnd =
  plotMapLinear f (case maybeStartEnd of
                    Nothing -> minimum l
                    (Just (start, _)) -> start)
                  (case maybeStartEnd of
                    Nothing -> maximum l
                    (Just (_, end)) -> end)
                   100
  where f x = sum (map (\xi -> gaussianPdf x xi h) l) / ((fromIntegral $ length l) * h)
        gaussianPdf x mu sigma = exp (- sqr (x - mu) / (2 * sigma)) / sqrt (2 * pi * sigma)
        sqr x = x * x

-- | Plot cross-correlation
xcorr x y = readData (x, y) % mp # "ax.xcorr(data[0], data[1]" ## ")"

-- | Plot auto-correlation
acorr x = readData x % mp # "ax.acorr(data" ## ")"

-- | Plot text at a specified location
text x y s = mp # "ax.text(" # x # "," # y # "," # raw s ## ")"

-- * Layout, axes, and legends

-- | Square up the aspect ratio of a plot.
squareAxes :: Matplotlib
squareAxes = mp # "ax.set_aspect('equal')"

-- | Set the rotation of the labels on the x axis to the given number of degrees
roateAxesLabels :: MplotValue val => val -> Matplotlib
roateAxesLabels degrees = mp # "labels = ax.get_xticklabels()"
   % mp # "for label in labels:"
   % mp # "    label.set_rotation("#degrees#")"

-- | Set the x labels to be vertical
verticalAxes :: Matplotlib
verticalAxes = mp # "labels = ax.get_xticklabels()"
   % mp # "for label in labels:"
   % mp # "    label.set_rotation('vertical')"

-- | Set the x scale to be logarithmic
logX :: Matplotlib
logX = mp # "ax.set_xscale('log')"

-- | Set the y scale to be logarithmic
logY :: Matplotlib
logY = mp # "ax.set_yscale('log')"

-- | Set limits on the x axis
xlim :: (MplotValue val1, MplotValue val) => val1 -> val -> Matplotlib
xlim l u = mp # "ax.set_xlim(" # l # "," # u # ")"

-- | Set limits on the y axis
ylim :: (MplotValue val1, MplotValue val) => val1 -> val -> Matplotlib
ylim l u = mp # "ax.set_ylim(" # l # "," # u # ")"

-- | Add a horizontal line across the axis
axhline y = mp # "ax.axhline(" # y ## ")"

-- | Insert a legend
legend = mp # "ax.legend(" ## ")"

-- | Insert a color bar
-- TODO This refers to the plot and not an axis. Might cause trouble with subplots
colorbar = mp # "plot.colorbar(" ## ")"

-- | Set the spacing of ticks on the x axis
axisXTickSpacing :: (MplotValue val1, MplotValue val) => val1 -> val -> Matplotlib
axisXTickSpacing nr width = mp # "ax.set_xticks(np.arange(" # nr # ")+" # width ## ")"

-- | Set the labels on the x axis
axisXTickLabels :: MplotValue val => val -> Matplotlib
axisXTickLabels labels = mp # "ax.set_xticklabels( (" # labels # ") " ## " )"

-- | Add a title
title :: String -> Matplotlib
title s = mp # "ax.set_title(" # raw s ## ")"

-- | Show/hide grid lines
grid :: Bool -> Matplotlib
grid t = mp # "ax.grid(" # t # ")"

-- | Enable 3D projection
axis3DProjection :: Matplotlib
axis3DProjection = mp # "ax = plot.gca(projection='3d')"

-- | Label and set limits of a set of 3D axis
-- TODO This is a mess, does both more and less than it claims.
axis3DLabels xs ys zs =
  mp # "ax.set_xlabel('X')"
  % mp # "ax.set_xlim3d(" # minimum2 xs # ", " # maximum2 xs # ")"
  % mp # "ax.set_ylabel('Y')"
  % mp # "ax.set_ylim3d(" # minimum2 ys # ", " # maximum2 ys # ")"
  % mp # "ax.set_zlabel('Z')"
  % mp # "ax.set_zlim3d(" # minimum2 zs # ", " # maximum2 zs # ")"

-- | Add a label to the x axis
xLabel :: String -> Matplotlib
xLabel label = mp # "ax.set_xlabel(" # raw label ## ")"

-- | Add a label to the y axis
yLabel :: String -> Matplotlib
yLabel label = mp # "ax.set_ylabel(" # raw label ## ")"

-- | Add a label to the z axis
zLabel :: String -> Matplotlib
zLabel label = mp # "ax.set_zlabel(" # raw label ## ")"

-- * Subplots

-- | Create a subplot with the coordinates (r,c,f)
addSubplot r c f = mp # "ax = plot.gcf().add_subplot(" # r # c # f ## ")" % updateAxes

-- | Access a subplot with the coordinates (r,c,f)
getSubplot r c f = mp # "ax = plot.subplot(" # r # "," # c # "," # f ## ")" % updateAxes

-- | Creates subplots and stores them in an internal variable
subplots = mp # "fig, axes = plot.subplots(" ## ")"

-- | Access a subplot
setSubplot s = mp # "ax = axes[" # s # "]"

-- | Add axes to a figure
axes = mp # "ax = axes(" ## ")" % updateAxes

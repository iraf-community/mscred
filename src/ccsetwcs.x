include <imhdr.h>
include <math.h>
include <math/gsurfit.h>
include <mwset.h>
include "skywcs.h"

# Define the possible pixel types

define  CC_PIXTYPESTR   "|logical|physical|"
define  CC_LOGICAL      1
define  CC_PHYSICAL     2


procedure t_ccsetwcs ()

char	image[SZ_FNAME]

char	wcssol[SZ_LINE], database[SZ_FNAME], solution[SZ_FNAME]
pointer	im, mw, immap(), ccsetwcs()
int	nscan()

begin
	call clgstr ("image", image, SZ_FNAME)

	im = immap (image, READ_WRITE, 0)
	ifnoerr (call imgstr (im, "wcssol", wcssol, SZ_LINE)) {
	    call sscan (wcssol)
	    call gargwrd (database, SZ_FNAME)
	    call gargwrd (solution, SZ_FNAME)
	    if (nscan() != 2)
		call error (1, "Invalid WCSSOL keyword")
	    mw = ccsetwcs (im, database, solution)
	    if (mw != NULL) {
		call mw_saveim (mw, im)
		call mw_close (mw)
		call imdelf (im, "wcssol")
	    }
	}
	call imunmap (im)
end


# CCSETWCS -- Read database and return MWCS pointer.

pointer procedure ccsetwcs (im, database, solution)

pointer	im			#I IMIO pointer
char	database[ARB]		#I Database
char	solution[ARB]		#I Database solution
pointer	mw			#O MWCS pointer

double	xref, yref, xscale, yscale, xrot, yrot, lngref, latref
int	recstat, proj
bool	transpose
pointer	sp, projstr
pointer	dt, coo, sx1, sy1, sx2, sy2
int	cc_dtwcs(), strdic()
pointer	dtmap(), cc_nwcsim()
errchk	dtmap, cc_dtwcs, cc_nwcsim

begin
	call smark (sp)
	call salloc (projstr, SZ_LINE, TY_CHAR)

	mw = NULL

	# Get database solution.
	sx1 = NULL; sx2 = NULL
	sy1 = NULL; sy2 = NULL
	coo = NULL
	dt = dtmap (database, READ_ONLY)
	recstat = cc_dtwcs (dt, solution, coo, Memc[projstr], lngref, latref,
	    sx1, sy1, sx2, sy2, xref, yref, xscale, yscale, xrot, yrot)
	call dtunmap (dt)

	# Get MWCS pointer.
	if (recstat != ERR) {
	    proj = strdic (Memc[projstr], Memc[projstr], SZ_FNAME, WTYPE_LIST)
	    if (proj <= 0 || proj == WTYPE_LIN)
		Memc[projstr] = EOS
	    transpose = false
	    mw = cc_nwcsim (im, coo, Memc[projstr], lngref, latref,
		sx1, sy1, sx2, sy2, transpose)
	}

	# Free memory.
	if (coo != NULL)
	    call sk_close (coo)
	if (sx1 != NULL)
	    call dgsfree (sx1)
	if (sy1 != NULL)
	    call dgsfree (sy1)
	call sfree (sp)

	return (mw)
end


# CC_DTWCS -- Read the wcs from the database records written by CCMAP.

int procedure cc_dtwcs (dt, record, coo, projection, lngref, latref, sx1, sy1,
        sx2, sy2, xref, yref, xscale, yscale, xrot, yrot)

pointer dt                      #I pointer to the database
char    record[ARB]             #I the database records to be read
pointer coo                     #O pointer to the coordinate structure
char    projection[ARB]         #O the sky projection geometry
double  lngref, latref          #O the reference point world coordinates
pointer sx1, sy1                #O pointer to the linear x and y fits
pointer sx2, sy2                #O pointer to the distortion x and y fits
double  xref, yref              #O the reference point in pixels
double  xscale, yscale          #O the x and y scale factors
double  xrot, yrot              #O the x and y axis rotation angles

int     i, op, ncoeff, junk, rec, coostat, lngunits, latunits, pixsys
double  xshift, yshift, a, b, c, d, denom
pointer sp, xcoeff, ycoeff, nxcoeff, nycoeff, mw, projpar, projvalue
bool    fp_equald()
double  dtgetd()
int     dtlocate(), dtgeti(), dtscan(), sk_decwcs(), strdic(), strlen()
int     gstrcpy()
errchk  dtgstr(), dtgetd(), dtgeti(), dgsrestore()

begin
        # Locate the appropriate records.
        iferr (rec = dtlocate (dt, record))
            return (ERR)

        # Open the coordinate structure.
        iferr (call dtgstr (dt, rec, "coosystem", projection, SZ_FNAME))
            return (ERR)
        coostat = sk_decwcs (projection, mw, coo, NULL)
        if (coostat == ERR || mw != NULL) {
            if (mw != NULL)
                call mw_close (mw)
            projection[1] = EOS
            return (ERR)
        }

        # Get the pixel coordinate system.
        iferr (call dtgstr (dt, rec, "pixsystem", projection, SZ_FNAME)) {
            pixsys = PIXTYPE_LOGICAL
        } else {
            pixsys = strdic (projection, projection, SZ_FNAME, PIXTYPE_LIST)
            if (pixsys != PIXTYPE_PHYSICAL)
                pixsys = PIXTYPE_LOGICAL
        }
        call sk_seti (coo, S_PTYPE, pixsys)


        # Get the reference point units.
        iferr (call dtgstr (dt, rec, "lngunits", projection, SZ_FNAME))
            return (ERR)
        lngunits = strdic (projection, projection, SZ_FNAME, SKY_LNG_UNITLIST)
        if (lngunits > 0)
            call sk_seti (coo, S_NLNGUNITS, lngunits)
        iferr (call dtgstr (dt, rec, "latunits", projection, SZ_FNAME))
            return (ERR)
        latunits = strdic (projection, projection, SZ_FNAME, SKY_LAT_UNITLIST)
        if (latunits > 0)
            call sk_seti (coo, S_NLATUNITS, latunits)

        # Get the reference point.
        iferr (call dtgstr (dt, rec, "projection", projection, SZ_FNAME))
            return (ERR)
        iferr (lngref = dtgetd (dt, rec, "lngref"))
            return (ERR)
        iferr (latref = dtgetd (dt, rec, "latref"))
            return (ERR)

        # Read in the coefficients.
        iferr (ncoeff = dtgeti (dt, rec, "surface1"))
            return (ERR)
        call smark (sp)
        call salloc (xcoeff, ncoeff, TY_DOUBLE)
        call salloc (ycoeff, ncoeff, TY_DOUBLE)
        do i = 1, ncoeff {
            junk = dtscan(dt)
            call gargd (Memd[xcoeff+i-1])
            call gargd (Memd[ycoeff+i-1])
        }

        # Restore the linear part of the fit.
        call dgsrestore (sx1, Memd[xcoeff])
        call dgsrestore (sy1, Memd[ycoeff])

        # Get and restore the distortion part of the fit.
        ncoeff = dtgeti (dt, rec, "surface2")
        if (ncoeff > 0) {
            call salloc (nxcoeff, ncoeff, TY_DOUBLE)
            call salloc (nycoeff, ncoeff, TY_DOUBLE)
            do i = 1, ncoeff {
                junk = dtscan(dt)
                call gargd (Memd[nxcoeff+i-1])
                call gargd (Memd[nycoeff+i-1])
            }
            iferr {
                call dgsrestore (sx2, Memd[nxcoeff])
            } then {
                call mfree (sx2, TY_STRUCT)
                sx2 = NULL
            }
            iferr {
                call dgsrestore (sy2, Memd[nycoeff])
            } then {
                call mfree (sy2, TY_STRUCT)
                sy2 = NULL
            }
        } else {
            sx2 = NULL
            sy2 = NULL
        }
        # Compute the coefficients.
        call geo_gcoeffd (sx1, sy1, xshift, yshift, a, b, c, d)

        # Compute the reference point.
        denom = a * d - c * b
        if (denom == 0.0d0)
            xref = INDEFD
        else
            xref = (b * yshift - d * xshift) / denom
        if (denom == 0.0d0)
            yref = INDEFD
        else
            yref =  (c * xshift - a * yshift) / denom

        # Compute the scale factors.
        xscale = sqrt (a * a + c * c)
        yscale = sqrt (b * b + d * d)

        # Compute the rotation angles.
        if (fp_equald (a, 0.0d0) && fp_equald (c, 0.0d0))
            xrot = 0.0d0
        else
            xrot = RADTODEG (atan2 (-c, a))
        if (xrot < 0.0d0)
            xrot = xrot + 360.0d0
        if (fp_equald (b, 0.0d0) && fp_equald (d, 0.0d0))
            yrot = 0.0d0
        else
            yrot = RADTODEG (atan2 (b, d))
        if (yrot < 0.0d0)
            yrot = yrot + 360.0d0

        # Read in up to 10 projection parameters.
        call salloc (projpar, SZ_FNAME, TY_CHAR)
        call salloc (projvalue, SZ_FNAME, TY_CHAR)
        op = strlen (projection) + 1
        do i = 0, 9 {
            call sprintf (Memc[projpar], SZ_FNAME, "projp%d")
                call pargi (i)
            iferr (call dtgstr (dt, rec, Memc[projpar], Memc[projvalue],
                SZ_FNAME))
                next
            op = op + gstrcpy (" ", projection[op], SZ_LINE - op + 1)
            op = op + gstrcpy (Memc[projpar], projection[op],
                SZ_LINE - op + 1)
            op = op + gstrcpy (" = ", projection[op], SZ_LINE - op + 1)
            op = op + gstrcpy (Memc[projvalue], projection[op],
                SZ_LINE - op + 1)
        }

        call sfree (sp)

        return (OK)
end


# CC_RPROJ -- Read the projection parameters from a file into an IRAF string
# containing the projection type followed by an MWCS WAT string, e.g
# "zpn projp1=value projp2=value" .

int procedure cc_rdproj (fd, projstr, maxch)

int     fd              #I the input file containing the projection parameters
char    projstr[ARB]    #O the output projection parameters string
int     maxch           #I the maximum size of the output projection string

int     projection, op
pointer sp, keyword, value, param
int     fscan(), nscan(), strdic(), gstrcpy()

begin
        projstr[1] = EOS
        if (fscan (fd) == EOF)
            return (0)

        call smark (sp)
        call salloc (keyword, SZ_FNAME, TY_CHAR)
        call salloc (value, SZ_FNAME, TY_CHAR)
        call salloc (param, SZ_FNAME, TY_CHAR)

        call gargwrd (Memc[keyword], SZ_FNAME)
        projection = strdic (Memc[keyword], Memc[keyword], SZ_FNAME,
            WTYPE_LIST)
        if (projection <= 0 || projection == WTYPE_LIN || nscan() == 0) {
            call sfree (sp)
            return (0)
        }

        # Copy the projection function into the projection string.
        op = 1
        op = op + gstrcpy (Memc[keyword], projstr[op], maxch)

        # Copy the keyword value pairs into the projection string.
        while (fscan(fd) != EOF) {
            call gargwrd (Memc[keyword], SZ_FNAME)
            call gargwrd (Memc[value], SZ_FNAME)
            if (nscan() != 2)
                next
            call sprintf (Memc[param], SZ_FNAME, " %s = %s")
                call pargstr (Memc[keyword])
                call pargstr (Memc[value])
            op = op + gstrcpy (Memc[param], projstr[op], maxch - op + 1)
        }

        call sfree (sp)

        return (projection)
end


define  NEWCD     Memd[ncd+(($2)-1)*ndim+($1)-1]

# CC_NWCSIM -- Set MWCS pointer.
#
# This is changed from the IMCOORDS version to
# 1. Return the mwcs pointer rather than update the image
# 2. If the database has a projection of tan and higher order terms set
#    a tnx projection
# 3. Set the reference point to the one in the image rather than the database.

pointer procedure cc_nwcsim (im, coo, projection, lngref, latref, sx1, sy1,
	sx2, sy2, transpose)

pointer im                      #I the pointer to the input image
pointer coo                     #I the pointer to the coordinate structure
char    projection[ARB]         #I the sky projection geometry
double  lngref, latref          #I the position of the reference point.
pointer sx1, sy1                #I pointer to linear surfaces
pointer sx2, sy2                #I pointer to distortion surfaces
bool    transpose               #I transpose the wcs
pointer	mwnew			#O MWCS pointer

int     l, i, ndim, naxes, ax1, ax2, axmap, wtype, szatstr
double  xshift, yshift, a, b, c, d, denom, xpix, ypix, tlngref, tlatref
pointer mw, sp, r, w, cd, ltm, ltv, iltm, nr, ncd, axes, axno, axval
pointer projstr, projpars, wpars, atstr
bool    streq()
int     mw_stati(), sk_stati(), strdic(), strlen(), itoc()
pointer mw_openim(), mw_open()
errchk  mw_gwattrs(), mw_newsystem()

begin
        # Open the image wcs and determine its size.
        mw = mw_openim (im)
        ndim = mw_stati (mw, MW_NPHYSDIM)

        # Allocate working memory for the wcs attributes, vectors, and
        # matrices.
        call smark (sp)
        call salloc (projstr, SZ_FNAME, TY_CHAR)
        call salloc (projpars, SZ_LINE, TY_CHAR)
        call salloc (wpars, SZ_LINE, TY_CHAR)
        call salloc (axno, IM_MAXDIM, TY_INT)
        call salloc (axval, IM_MAXDIM, TY_INT)
        call salloc (axes, IM_MAXDIM, TY_INT)
        call salloc (r, ndim, TY_DOUBLE)
        call salloc (w, ndim, TY_DOUBLE)
        call salloc (cd, ndim * ndim, TY_DOUBLE)
        call salloc (ltm, ndim * ndim, TY_DOUBLE)
        call salloc (ltv, ndim, TY_DOUBLE)
        call salloc (iltm, ndim * ndim, TY_DOUBLE)
        call salloc (nr, ndim, TY_DOUBLE)
        call salloc (ncd, ndim * ndim, TY_DOUBLE)

	# Get the image reference point.
	call mw_gwtermd (mw, Memd[nr], Memd[w], Memd[ncd], ndim)
	lngref = Memd[w]
	latref = Memd[w+1]
	call sk_seti (coo, S_NLNGUNITS, SKY_DEGREES)
	call sk_seti (coo, S_NLATUNITS, SKY_DEGREES)

        # Open the new wcs and set the system type.
        mwnew = mw_open (NULL, ndim)
        call mw_gsystem (mw, Memc[projstr], SZ_FNAME)
        iferr {
            call mw_newsystem (mw, "image", ndim)
        } then {
            call mw_newsystem (mwnew, Memc[projstr], ndim)
        } else {
            call mw_newsystem (mwnew, "image", ndim)
        }

        # Set the LTERM.
        call mw_gltermd (mw, Memd[ltm], Memd[ltv], ndim)
        call mw_sltermd (mwnew, Memd[ltm], Memd[ltv], ndim)

        # Store the old axis map for later use.
        call mw_gaxmap (mw, Memi[axno], Memi[axval], ndim)

        # Get the celestial coordinate axes list.
        call mw_gaxlist (mw, 03B, Memi[axes], naxes)
        axmap = mw_stati (mw, MW_USEAXMAP)
        ax1 = Memi[axes]
        ax2 = Memi[axes+1]

        # Set the axes and projection type for the celestial coordinate
        # axes. Don't worry about the fact that the axes may in fact be
        # glon and glat, elon and elat, or slon and slat, instead of
        # ra and dec. This will be fixed up later.
        if (projection[1] == EOS) {
            call mw_swtype (mwnew, Memi[axes], ndim, "linear", "")
        } else {
            call sscan (projection)
                call gargwrd (Memc[projstr], SZ_FNAME)
                call gargstr (Memc[projpars], SZ_LINE)
            call sprintf (Memc[wpars], SZ_LINE,
                "axis 1: axtype = ra %s axis 2: axtype = dec %s")
                call pargstr (Memc[projpars])
                call pargstr (Memc[projpars])
            if (streq (Memc[projstr], "tnx") && sx2 == NULL && sy2 == NULL)
                call strcpy ("tan", Memc[projstr], SZ_FNAME)
            else if (streq (Memc[projstr], "tan") && (sx2!=NULL || sy2==NULL))
                call strcpy ("tnx", Memc[projstr], SZ_FNAME)
            call mw_swtype (mwnew, Memi[axes], ndim, Memc[projstr], Memc[wpars])
        }

        # Copy the attributes of the remaining axes to the new wcs.
        szatstr = SZ_LINE
        call malloc (atstr, szatstr, TY_CHAR)
        do l = 1, ndim {
            if (l == ax1 || l == ax2)
                next
            iferr {
                call mw_gwattrs (mw, l, "wtype", Memc[projpars], SZ_LINE)
            } then {
                call mw_swtype (mwnew, l, 1, "linear", "")
            } else {
                call mw_swtype (mwnew, l, 1, Memc[projpars], "")
            }
            for (i = 1; ; i = i + 1) {
                if (itoc (i, Memc[projpars], SZ_LINE) <= 0)
                    Memc[projpars] = EOS
                repeat {
                    iferr (call mw_gwattrs (mw, l, Memc[projpars],
                        Memc[atstr], szatstr))
                        Memc[atstr] = EOS
                    if (strlen(Memc[atstr]) < szatstr)
                        break
                    szatstr = szatstr + SZ_LINE
                    call realloc (atstr, szatstr, TY_CHAR)
                }
                if (Memc[atstr] == EOS)
                    break
                call mw_swattrs (mwnew, l, Memc[projpars], Memc[atstr])
            }
        }
        call mfree (atstr, TY_CHAR)

        # Compute the new referemce point.

        switch (sk_stati(coo, S_NLNGUNITS)) {
        case SKY_DEGREES:
            tlngref = lngref
        case SKY_RADIANS:
            tlngref = RADTODEG(lngref)
        case SKY_HOURS:
            tlngref = 15.0d0 * lngref
        default:
            tlngref = lngref
        }
        switch (sk_stati(coo, S_NLATUNITS)) {
        case SKY_DEGREES:
            tlatref = latref
        case SKY_RADIANS:
            tlatref = RADTODEG(latref)
        case SKY_HOURS:
            tlatref = 15.0d0 * latref
        default:
            tlatref = latref
        }
        if (! transpose) {
            Memd[w+ax1-1] = tlngref
            Memd[w+ax2-1] = tlatref
        } else {
            Memd[w+ax1-1] = tlatref
            Memd[w+ax2-1] = tlngref
        }
        # Fetch the linear coefficients of the fit.
        call geo_gcoeffd (sx1, sy1, xshift, yshift, a, b, c, d)

        # Compute the new reference pixel.
        denom = a * d - c * b
        if (denom == 0.0d0)
            xpix = INDEFD
        else
            xpix = (b * yshift - d * xshift) / denom
        if (denom == 0.0d0)
            ypix = INDEFD
        else
            ypix =  (c * xshift - a * yshift) / denom
        Memd[nr+ax1-1] = xpix
        Memd[nr+ax2-1] = ypix

        # Compute the new CD matrix.
        if (! transpose) {
            NEWCD(ax1,ax1) = a / 3600.0d0
            NEWCD(ax1,ax2) = c / 3600.0d0
            NEWCD(ax2,ax1) = b / 3600.0d0
            NEWCD(ax2,ax2) = d / 3600.0d0
        } else {
            NEWCD(ax1,ax1) = c / 3600.0d0
            NEWCD(ax1,ax2) = a / 3600.0d0
            NEWCD(ax2,ax1) = d / 3600.0d0
            NEWCD(ax2,ax2) = b / 3600.0d0
        }

        # Recompute and store the new wcs.
        call mw_saxmap (mwnew, Memi[axno], Memi[axval], ndim)
        if (sk_stati (coo, S_PTYPE) == PIXTYPE_PHYSICAL) {
            call mw_swtermd (mwnew, Memd[nr], Memd[w], Memd[ncd], ndim)
        } else {
            call mwmmuld (Memd[ncd], Memd[ltm], Memd[cd], ndim)
            call mwinvertd (Memd[ltm], Memd[iltm], ndim)
            call asubd (Memd[nr], Memd[ltv], Memd[r], ndim)
            call mwvmuld (Memd[iltm], Memd[r], Memd[nr], ndim)
            call mw_swtermd (mwnew, Memd[nr], Memd[w], Memd[cd], ndim)
        }

        # Add the second order terms in the form of the wcs attributes
        # lngcor and latcor. These are not FITS standard and can currently
        # be understood only by IRAF.
        if ((streq(Memc[projstr], "zpx") || streq (Memc[projstr], "tnx")) &&
            (sx2 != NULL || sy2 != NULL)) {
            if (! transpose)
                call cc_wcscor (im, mwnew, sx1, sx2, sy1, sy2, "lngcor",
                    "latcor", ax1, ax2)
            else
                call cc_wcscor (im, mwnew, sx1, sx2, sy1, sy2, "lngcor",
                    "latcor", ax2, ax1)
        }

        # Save the fit.
        if (! transpose) {
            call sk_seti (coo, S_PLNGAX, ax1)
            call sk_seti (coo, S_PLATAX, ax2)
        } else {
            call sk_seti (coo, S_PLNGAX, ax2)
            call sk_seti (coo, S_PLATAX, ax1)
        }
        call sk_hdrsaveim (coo, mwnew, im)
        #call mw_saveim (mwnew, im)
        #call mw_close (mwnew)
        call mw_close (mw)

        # Force the CTYPE keywords to update. This will be unecessary when
        # mwcs is updated to deal with non-quoted and / or non left-justified
        # CTYPE keywords..
        wtype = strdic (Memc[projstr], Memc[projstr], SZ_FNAME, WTYPE_LIST)
        if (wtype > 0)
            call sk_seti (coo, S_WTYPE, wtype)
        #call sk_ctypeim (coo, im)

        # Reset the fit.
        #call sk_seti (coo, S_WTYPE, 0)
        #call sk_seti (coo, S_PLNGAX, 0)
        #call sk_seti (coo, S_PLATAX, 0)

        call sfree (sp)

	return (mwnew)
end


# CC_WCSCOR -- Reformulate the higher order surface fit into a correction
# term in degrees that can be written into the header as a wcs attribute.
# This attribute will be written as string containing the surface definition.

procedure cc_wcscor (im, mw, sx1, sx2, sy1, sy2, xiname, etaname, xiaxis,
        etaaxis)

pointer im              #I pointer to the input image
pointer mw              #I pointer to the wcs structure
pointer sx1, sx2        #I pointer to the linear and distortion xi surfaces
pointer sy1, sy2        #I pointer to the linear and distortion eta surfaces
char    xiname[ARB]     #I the wcs xi correction attribute name
char    etaname[ARB]    #I the wcs eta correction attribute name
int     xiaxis          #I the xi axis number
int     etaaxis         #I the eta axis number

int     i, j, function, xxorder, xyorder, xxterms, yxorder, yyorder, yxterms
int     nx, ny, npix, ier
double  sxmin, sxmax, symin, symax, ratio, x, y, xstep, ystep, ximin, ximax
double  etamin, etamax
pointer sp, xpix, ypix, xilin, etalin, dxi, deta, wgt, nsx2, nsy2
int     dgsgeti()
double  dgsgetd()
begin
        if (sx2 == NULL && sy2 == NULL)
            return
        if (dgsgeti (sx1, GSTYPE) != dgsgeti (sy1, GSTYPE))
            return

        # Get the function, xmin, xmax, ymin, and ymax parameters for the
        # surfaces.
        function = min (dgsgeti (sx1, GSTYPE), dgsgeti (sy1, GSTYPE))
        sxmin = max (dgsgetd (sx1, GSXMIN), dgsgetd (sy1, GSXMIN))
        sxmax = min (dgsgetd (sx1, GSXMAX), dgsgetd (sy1, GSXMAX))
        symin = max (dgsgetd (sx1, GSYMIN), dgsgetd (sy1, GSYMIN))
        symax = min (dgsgetd (sx1, GSYMAX), dgsgetd (sy1, GSYMAX))

        # Get the order and cross-terms parameters from the higher order
        # functions.
        if (sx2 != NULL) {
            xxorder = dgsgeti (sx2, GSXORDER)
            xyorder = dgsgeti (sx2, GSYORDER)
            xxterms = dgsgeti (sx2, GSXTERMS)
        } else {
            xxorder = dgsgeti (sx1, GSXORDER)
            xyorder = dgsgeti (sx1, GSYORDER)
            xxterms = dgsgeti (sx1, GSXTERMS)
        }
        if (sy2 != NULL) {
            yxorder = dgsgeti (sy2, GSXORDER)
            yyorder = dgsgeti (sy2, GSYORDER)
            yxterms = dgsgeti (sy2, GSXTERMS)
        } else {
            yxorder = dgsgeti (sy1, GSXORDER)
            yyorder = dgsgeti (sy1, GSYORDER)
            yxterms = dgsgeti (sy1, GSXTERMS)
        }

        # Choose a reasonable coordinate grid size based on the x and y order
        # of the fit and the number of rows and columns in the image.
        ratio = double (IM_LEN(im,2)) / double (IM_LEN(im,1))
        nx = max (xxorder + 3, yxorder + 3, 10)
        ny = max (yyorder + 3, xyorder + 3, nint (ratio * 10))
        npix = nx * ny

        # Allocate some working space.
        call smark (sp)
        call salloc (xpix, npix, TY_DOUBLE)
        call salloc (ypix, npix, TY_DOUBLE)
        call salloc (xilin, npix, TY_DOUBLE)
        call salloc (etalin, npix, TY_DOUBLE)
        call salloc (dxi, npix, TY_DOUBLE)
        call salloc (deta, npix, TY_DOUBLE)
        call salloc (wgt, npix, TY_DOUBLE)

        # Compute the grid of x and y points.
        xstep = (sxmax - sxmin) / (nx - 1)
        ystep = (symax - symin) / (ny - 1)
        y = symin
        npix = 0
        do j = 1, ny {
            x = sxmin
            do i = 1, nx {
                Memd[xpix+npix] = x
                Memd[ypix+npix] = y
                x = x + xstep
                npix = npix + 1
            }
            y = y + ystep
        }


        # Compute the weights
        call amovkd (1.0d0, Memd[wgt], npix)

        # Evalute the linear surfaces and convert the results from arcseconds
        # to degrees.
        call dgsvector (sx1, Memd[xpix], Memd[ypix], Memd[xilin], npix)
        call adivkd (Memd[xilin], 3600.0d0, Memd[xilin], npix)
        call alimd (Memd[xilin], npix, ximin, ximax)
        call dgsvector (sy1, Memd[xpix], Memd[ypix], Memd[etalin], npix)
        call adivkd (Memd[etalin], 3600.0d0, Memd[etalin], npix)
        call alimd (Memd[etalin], npix, etamin, etamax)

        # Evalute the distortion surfaces, convert the results from arcseconds
        # to degrees, and compute new distortion surfaces.
        if (sx2 != NULL) {
            call dgsvector (sx2, Memd[xpix], Memd[ypix], Memd[dxi], npix)
            call adivkd (Memd[dxi], 3600.0d0, Memd[dxi], npix)
            call dgsinit (nsx2, function, xxorder, xyorder, xxterms,
               ximin, ximax, etamin, etamax)
            call dgsfit (nsx2, Memd[xilin], Memd[etalin], Memd[dxi],
                Memd[wgt], npix, WTS_UNIFORM, ier)
            call cc_gsencode (mw, nsx2, xiname, xiaxis)
        } else
            nsx2 = NULL
        if (sy2 != NULL) {
            call dgsvector (sy2, Memd[xpix], Memd[ypix], Memd[deta], npix)
            call adivkd (Memd[deta], 3600.0d0, Memd[deta], npix)
            call dgsinit (nsy2, function, yxorder, yyorder, yxterms,
               ximin, ximax, etamin, etamax)
            call dgsfit (nsy2, Memd[xilin], Memd[etalin], Memd[deta],
                Memd[wgt], npix, WTS_UNIFORM, ier)
            call cc_gsencode (mw, nsy2, etaname, etaaxis)
        } else
            nsy2 = NULL

        # Store the string in the mcs structure in the format of a wcs
        # attribute.

        # Free the new surfaces.
        if (nsx2 != NULL)
            call dgsfree (nsx2)
        if (nsy2 != NULL)
            call dgsfree (nsy2)

        call sfree (sp)
end


# CC_GSENCODE -- Encode the surface in an mwcs attribute.

procedure cc_gsencode (mw, gs, atname, axis)

pointer mw              #I pointer to the mwcs structure
pointer gs              #I pointer to the surface to be encoded
char    atname[ARB]     #I attribute name for the encoded surface
int     axis            #I axis for which the encode surface is encoded

int     i, op, nsave, szatstr, szpar
pointer sp, coeff, par, atstr
int     dgsgeti(), strlen(), gstrcpy()

begin
        nsave = dgsgeti (gs, GSNSAVE)
        call smark (sp)
        call salloc (coeff, nsave, TY_DOUBLE)
        call salloc (par, SZ_LINE, TY_CHAR)
        call dgssave (gs, Memd[coeff])

        szatstr = SZ_LINE
        call malloc (atstr, szatstr, TY_CHAR)
        op = 0
        do i = 1, nsave {
            call sprintf (Memc[par], SZ_LINE, "%g ")
                call pargd (Memd[coeff+i-1])
            szpar = strlen (Memc[par])
            if (szpar > (szatstr - op)) {
                szatstr = szatstr + SZ_LINE
                call realloc (atstr, szatstr, TY_CHAR)
            }
            op = op + gstrcpy (Memc[par], Memc[atstr+op], SZ_LINE)

        }

        call mw_swattrs (mw, axis, atname, Memc[atstr])
        call mfree (atstr, TY_CHAR)
        call sfree (sp)
end


# GEO_GCOEFF -- Print the coefficents of the linear portion of the
# fit, xshift, yshift, 

procedure geo_gcoeffd (sx, sy, xshift, yshift, a, b, c, d)

pointer	sx		#I pointer to the x surface fit
pointer	sy		#I pointer to the y surface fit
double	xshift		#O output x shift
double	yshift		#O output y shift
double	a		#O output x coefficient of x fit
double	b		#O output y coefficient of x fit
double	c		#O output x coefficient of y fit
double	d		#O output y coefficient of y fit

int	nxxcoeff, nxycoeff, nyxcoeff, nyycoeff
pointer	sp, xcoeff, ycoeff
double	xxrange, xyrange, xxmaxmin, xymaxmin
double	yxrange, yyrange, yxmaxmin, yymaxmin

int	dgsgeti()
double	dgsgetd()

begin
	# Allocate working space.
	call smark (sp)
	call salloc (xcoeff, dgsgeti (sx, GSNCOEFF), TY_DOUBLE)
	call salloc (ycoeff, dgsgeti (sy, GSNCOEFF), TY_DOUBLE)

	# Get coefficients and numbers of coefficients.
	call dgscoeff (sx, Memd[xcoeff], nxxcoeff)
	call dgscoeff (sy, Memd[ycoeff], nyycoeff)
	nxxcoeff = dgsgeti (sx, GSNXCOEFF)
	nxycoeff = dgsgeti (sx, GSNYCOEFF)
	nyxcoeff = dgsgeti (sy, GSNXCOEFF)
	nyycoeff = dgsgeti (sy, GSNYCOEFF)

	# Get the data range.
	if (dgsgeti (sx, GSTYPE) != GS_POLYNOMIAL) {
	    xxrange = (dgsgetd (sx, GSXMAX) - dgsgetd (sx, GSXMIN)) / 2.0d0
	    xxmaxmin = - (dgsgetd (sx, GSXMAX) + dgsgetd (sx, GSXMIN)) / 2.0d0
	    xyrange = (dgsgetd (sx, GSYMAX) - dgsgetd (sx, GSYMIN)) / 2.0d0
	    xymaxmin = - (dgsgetd (sx, GSYMAX) + dgsgetd (sx, GSYMIN)) / 2.0d0
	} else {
	    xxrange = double(1.0)
	    xxmaxmin = double(0.0)
	    xyrange = double(1.0)
	    xymaxmin = double(0.0)
	}

	if (dgsgeti (sy, GSTYPE) != GS_POLYNOMIAL) {
	    yxrange = (dgsgetd (sy, GSXMAX) - dgsgetd (sy, GSXMIN)) / 2.0d0
	    yxmaxmin = - (dgsgetd (sy, GSXMAX) + dgsgetd (sy, GSXMIN)) / 2.0d0
	    yyrange = (dgsgetd (sy, GSYMAX) - dgsgetd (sy, GSYMIN)) / 2.0d0
	    yymaxmin = - (dgsgetd (sy, GSYMAX) + dgsgetd (sy, GSYMIN)) / 2.0d0
	} else {
	    yxrange = double(1.0)
	    yxmaxmin = double(0.0)
	    yyrange = double(1.0)
	    yymaxmin = double(0.0)
	}

	# Get the shifts.
	xshift = Memd[xcoeff] + Memd[xcoeff+1] * xxmaxmin / xxrange +
	    Memd[xcoeff+2] * xymaxmin / xyrange
	yshift = Memd[ycoeff] + Memd[ycoeff+1] * yxmaxmin / yxrange +
	    Memd[ycoeff+2] * yymaxmin / yyrange

	# Get the rotation and scaling parameters and correct for normalization.
	if (nxxcoeff > 1)
	    a = Memd[xcoeff+1] / xxrange
	else
	    a = double(0.0)
	if (nxycoeff > 1)
	    b = Memd[xcoeff+nxxcoeff] / xyrange
	else
	    b = double(0.0)
	if (nyxcoeff > 1)
	    c = Memd[ycoeff+1] / yxrange
	else
	    c = double(0.0)
	if (nyycoeff > 1)
	    d = Memd[ycoeff+nyxcoeff] / yyrange
	else
	    d = double(0.0)

	call sfree (sp)
end
